# GrowYield validation architecture

## Scope and pinned account

GrowYield is a selector-associated ERC-6900 UserOperation validator plus a tightly
bounded yield executor. This repository tests the integration against the actual
Alchemy `ModularAccount` source at tag `v2.0.1`, commit
`efab648bd91f79685571af7fa88171e3c142f2f6`, and EntryPoint v0.7.

The production account may use a multi-owner validation module for its normal owner
path. The local compatibility test uses a small SingleSigner harness for that owner
path; owner aggregation is independent of Grow's nonce routing and module payload.
If “MultiOwner Modular Account” means Alchemy's older v1 MSCA factory/plugin product
rather than a multi-owner validator installed on Modular Account v2, its encoder must
be verified separately—the two account generations do not share UserOperation
framing.

## System architecture

```mermaid
flowchart LR
    Owners["Smart-account owners\nstandard validation"]
    PolicyOwner["Grow policy owner\nautomation key"]
    Bundler[Bundler]
    EP["EntryPoint v0.7"]
    Account["Alchemy ModularAccount\nv2.0.1"]
    Policy["GrowYieldPolicyModule"]
    PolicyLib["GrowYieldPolicyLib"]
    Executor["GrowYieldExecutorV3"]
    Registry["GrowYieldAdapterRegistry\nconstructor-fixed"]
    Guardian["Risk guardian"]
    Aave[AaveV3Adapter]
    Morpho[MorphoVaultV2Adapter]
    EulerEVK[EulerEVaultAdapter]
    EulerEarn[EulerEarnAdapter]
    Capy[CapyFiAdapter]
    Venues["Aave / Morpho / Euler / CapyFi"]
    Paymaster["Pinned sponsor paymaster"]

    Owners -->|install, configure, rotate, revoke| Account
    PolicyOwner -->|sign exact UserOp| Bundler
    Bundler --> EP
    Paymaster -->|sponsor| EP
    EP --> Account
    Account -->|validateUserOp| Policy
    Policy --> PolicyLib
    Account -->|executeBatch| Executor
    Executor --> Registry
    Executor --> Aave
    Executor --> Morpho
    Executor --> EulerEVK
    Executor --> EulerEarn
    Executor --> Capy
    Aave --> Venues
    Morpho --> Venues
    EulerEVK --> Venues
    EulerEarn --> Venues
    Capy --> Venues
    Guardian -->|permanent deposit pause| Executor
```

The layers are deliberately separate:

| Layer | Enforced property |
|---|---|
| Alchemy account | Selects the installed validation entity and applies selector scope |
| Policy module | Authenticates an account-scoped policy owner and constrains UserOp fields |
| Policy library | Accepts only one canonical approve/execute/revoke batch shape |
| Executor | Pins recipients, resolves amounts, checks output floors, budgets, and pauses |
| Registry | Fixes adapter addresses, directions, token pairs, and runtime code hashes |
| Adapters | Translate the uniform executor API into venue-specific calls and drift checks |

## Contract catalogue

### `GrowYieldPolicyModule`

This is the UserOperation-only validation module. Per smart account it stores:

- The nonzero validation `entityId` chosen during installation.
- Up to eight policy-owner addresses.

The entity is account-configurable because ERC-6900 entity IDs are unique within an
account, not globally reserved. Example entity `1` is suitable only after confirming
that the account has not already allocated it.

For each UserOperation the module requires:

- The account calls the module on its own UserOperation (`msg.sender == userOp.sender`).
- The entity passed by the account equals the entity stored for that account.
- No `initCode`.
- The constructor-pinned paymaster.
- Verification, call, pre-verification, paymaster, priority-fee, and max-fee fields at
  or below immutable ceilings.
- Canonical Grow calldata accepted by `GrowYieldPolicyLib`.
- A 65-byte ECDSA authorization over the exact `userOpHash`.
- A recovered signer present in the account's policy-owner set.

The module returns no ERC-4337 time range and does not read `block.timestamp` during
validation.

Policy-owner management functions are `addOwner` and `removeOwner`. They
key changes by `msg.sender`, so the smart account itself must call them through its
normal owner-authorized path. The Grow policy cannot call either function.

### `GrowYieldPolicyLib`

The library accepts exactly this `executeBatch` shape:

```text
approve(sourceToken[0], executor, uint256.max)
...
approve(sourceToken[n], executor, uint256.max)
executor.execute(Operation[])
approve(sourceToken[0], executor, 0)
...
approve(sourceToken[n], executor, 0)
```

Source tokens are the unique operation source tokens in first-appearance order. The
library rejects noncanonical ABI, native value, self-calls, extra bytes, more than
four operations, zero adapters/tokens, and any operation without an absolute output
floor. The executor independently re-derives each token from the adapter.

### `GrowYieldExecutorV3`

Every operation is signed as the following static tuple:

```solidity
struct Operation {
    IYieldAdapter adapter;
    OperationKind kind;       // DEPOSIT or REDEEM
    address sourceToken;
    uint256 amount;
    AmountMode amountMode;    // EXACT, FULL_BALANCE, PREVIOUS_OUTPUT
    uint256 minAmountOut;     // absolute signed floor
}
```

Amount modes are explicit:

| Mode | Meaning |
|---|---|
| `EXACT` | Use the nonzero signed `amount` |
| `FULL_BALANCE` | Use the caller's current source-token balance; `amount` must be zero |
| `PREVIOUS_OUTPUT` | Use only the immediately preceding operation's measured output; `amount` must be zero and tokens must match |

`PREVIOUS_OUTPUT` is the safe rebalance mode. It prevents a rebalance from sweeping
unrelated idle underlying already held by the account.

For every operation the executor:

1. Confirms registry direction, account policy, code hash, and deposit-pause state.
2. Re-derives source and output tokens and checks the signed source declaration.
3. Resolves the explicit amount mode and consumes the directional epoch budget.
4. Reads the adapter preview.
5. Transfers the exact source amount directly from the account to the adapter.
6. Invokes the adapter, which credits output directly to the account.
7. Rejects new residual balances or fee-on-transfer source behavior.
8. Measures actual account output.
9. Requires output to meet both the preview-relative floor and signed absolute floor.

The effective floor is:

```text
max(
  ceil(preview * (10_000 - maxLossBps) / 10_000),
  operation.minAmountOut
)
```

The preview-relative check limits unexpected venue slippage. The absolute floor
protects against a manipulated or compromised preview returning a misleading value.

### Adapter policies

Each account owns separate deposit and redeem source-volume limits for every fixed
adapter. `setAdapterPolicy` changes limits without clearing already-consumed volume.
Changing the epoch duration requires `resetAdapterPolicy`, which explicitly resets
usage and emits `AdapterPolicyUsageReset`.

`type(uint256).max` is rejected as `UnboundedPolicy`: it would make the quantitative
limit meaningless. Limits must be finite and chosen in the source token's native
units. Zero disables one direction; two zero limits revoke the adapter for that
account while retaining prior usage unless an explicit reset is requested.

### Risk guardian

The executor has one immutable `riskGuardian`. It can permanently pause new deposits
through a registered adapter. It cannot unpause, move funds, change limits, admit an
adapter, or block redemptions. This adds incident-response value without giving the
guardian a withdrawal or migration power. Recovery from a false pause requires a
new deployment and owner-approved migration.

### Trust boundary: authenticity vs Grow approval

Adapter constructor and per-operation protocol checks answer only:

> “Is this a genuine canonical deployment of the named protocol (Euler factory
> proxy / Earn vault / CapyFi listed market / Aave reserve / Morpho wrapper)?”

They do **not** answer:

> “Is this vault or market an acceptable Grow yield venue?”

That second decision is made solely by **including the adapter in the
constructor-fixed `GrowYieldAdapterRegistry`**. The registry is Grow's approval and
risk-admission layer: which venues exist, which directions are enabled, and which
runtime code hashes the executor will accept. A factory-authentic Euler vault that
is absent from the registry cannot be used. Conversely, registry inclusion without
passing the adapter's authenticity checks fails closed at construction or execution.

### `GrowYieldAdapterRegistry`

The registry is constructor-only and has no owner or mutation function. It records:

- Each adapter in constructor order.
- Deposit and redeem permissions.
- Each adapter's deployment-time runtime code hash.
- Each venue's position token → underlying binding.

Construction verifies the adapter's pinned executor, nonidentical deployed asset and
position tokens, unique adapter addresses, and unique position tokens (duplicate
venues or conflicting asset/position bindings revert). Enumeration through
`adapterCount` and `adapterAt` supports monitoring without adding mutation
authority. Proxies are still unsuitable: a proxy's runtime code hash can stay
constant while its implementation changes.

### `AaveV3Adapter`

The Aave adapter pins one pool, data provider, asset, aToken, and executor. Deposits
re-check that the reserve still points to the pinned aToken. It uses `forceApprove`,
supplies the exact amount, clears venue allowance, and verifies exact consumption.

Redemptions withdraw the exact caller-attributed aToken amount. They do not use
Aave's `uint256.max` sentinel and therefore do not sweep aToken donations already at
the adapter into another user's redemption.

### `MorphoVaultV2Adapter`

The Morpho adapter accepts only a factory-authenticated VaultV2 wrapper with one
factory-authenticated Morpho VaultV1 child adapter, matching assets, fixed liquidity
routing, empty liquidity data, and abdicated adapter-add/remove selectors.

Deposits re-check child eligibility, liquidity routing, and all required round-trip
gates. Deposit and redeem verify ERC-4626 receiver deltas and exact source
consumption. Later governance, gates, liquidity, or losses can still impair exits.

### Euler adapters (`AbstractEulerAdapter`)

Euler EVK (EVault) and Euler Earn both expose ERC-4626 `deposit` / `redeem` with a
receiver parameter, so Grow shares one immutable execution path in
`AbstractEulerAdapter`. They do **not** share factory authenticity APIs, so
protocol-specific subclasses perform only the venue proof:

| Adapter | Pinned contracts | Authenticity proof | Why it proves a valid **protocol** deployment |
|---|---|---|---|
| `EulerEVaultAdapter` | EVK `GenericFactory`, EVault, underlying, executor | `factory.isProxy(vault)` and `vault.asset() == asset` | Only proxies created by the pinned EVK factory appear in `isProxy`; a fake ERC-4626 cannot pass. Re-checking `asset()` blocks a factory vault that was wired to a different underlying or later reports a drifted asset. **Not** a Grow risk approval. |
| `EulerEarnAdapter` | EulerEarnFactory, Earn vault, underlying, executor | `factory.isVault(vault)` and `vault.asset() == asset` | Only CREATE2 vaults registered by the pinned Earn factory return true from `isVault`. Asset re-check prevents binding Grow to the wrong underlying. **Not** a Grow risk approval. |

Both adapters re-run those checks before every deposit and redeem. Deposits use
`forceApprove`, credit shares **directly** to the smart account via ERC-4626
`deposit(assets, receiver)`, clear and assert zero vault allowance, require the
receiver share delta to match, and assert the adapter retained no new shares.
Redemptions use `redeem(shares, receiver, address(this))` so underlying is sent
**directly** to the account; the adapter holds shares only because the executor
transferred the attributed amount in, then consumes exactly that amount and asserts
no new underlying residual. Pre-existing share donations are not swept.

### `CapyFiAdapter`

CapyFi is Compound-v2 style: `mint` / `redeem` return error codes and credit
`msg.sender` rather than an arbitrary receiver. The adapter pins the executor,
canonical Comptroller (Unitroller), caToken, and underlying, then verifies:

| Check | Why it proves a valid **CapyFi protocol** market |
|---|---|
| `caToken.comptroller() == pinned Comptroller` | The market still belongs to the pinned risk engine, not a spoofed controller. **Not** a Grow risk approval. |
| `Comptroller.markets(caToken).isListed == true` | The Comptroller currently admits the market; delisting fails closed. |
| `caToken.underlying() == pinned asset` | The market cannot silently point at a different ERC-20. |

Non-zero Compound return codes from `mint` / `redeem` revert (`MintFailed` /
`RedeemFailed`). Deposits `forceApprove` the caToken, mint, clear and assert zero
allowance, then transfer only the newly minted caTokens to the smart account.
Redemptions: the executor transfers the exact caToken source amount to the adapter;
the adapter calls `redeem(shares)`, transfers **all** resulting underlying to the
account, and on a clean path (no prior donations) finishes with zero caToken,
underlying, and allowances. Donated caTokens already held by the adapter are not
swept into another account's redeem.

### Adding adapters: registry vs executor redeploy

The registry is constructor-fixed and has no mutation path. The executor attaches a
registry exactly once via `initializeRegistry` and then rejects further attachment.
Every adapter also immutably pins `executor`.

| Deployment state | What must be redeployed |
|---|---|
| Executor deployed but `initializeRegistry` not yet called | Deploy the new immutable adapters (pinning that executor), then deploy one complete registry containing the full intended adapter set, then call `initializeRegistry` once. **Registry-only attachment** — the executor bytecode need not change. |
| Executor already initialized with a registry | The live registry cannot admit new adapters and cannot be swapped. Deploy a **new executor**, new adapters pinned to that executor, a new complete registry, and (because the policy module constructor also pins the executor) a new policy module install on accounts that should use the expanded set. |

#### Live Base status (as of this change)

Historical Base deployments (`GrowYieldExecutorV6` at
`0x4Ac4BE21D3E285DD3A6c6e9B908fc84aC3E72306` and `GrowYieldExecutor1271V2` at
`0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE`) already have a registry attached, but
they are **not** `GrowYieldExecutorV3`. No `GrowYieldExecutorV3` production address
is recorded in this repository.

Therefore the intended path for the first V3 production stack is the **executor
stays / registry-once** route:

1. Deploy `GrowYieldExecutorV3` (and `GrowYieldPolicyModule`).
2. Deploy every intended immutable adapter pinned to that executor (Aave, Morpho,
   Euler EVK, Euler Earn, CapyFi, …).
3. Deploy one complete `GrowYieldAdapterRegistry` listing all of them.
4. Call `initializeRegistry` once from the executor deployer.

Do not attempt to hot-add Euler/CapyFi into the legacy V6/1271 registries.

Greenfield production therefore should include every intended venue in the first
registry whenever possible. Expanding venues after initialization is an executor-stack
migration, not a registry hot-add.

Fork-tested venue constructor arguments and authenticity results are recorded in
[`ADAPTER-DEPLOYMENT-MATRIX.md`](ADAPTER-DEPLOYMENT-MATRIX.md).

## How Alchemy chooses Grow instead of the owner validator

Alchemy Modular Account v2.0.1 derives a validation locator from the high 192-bit
EntryPoint nonce key. For a normal entity validation:

```text
nonceKey = (uint192(entityId) << 8) | options
```

The low option bit means global validation. With an example Grow entity of `1`:

| Path | Entity | Options | Nonce key |
|---|---:|---:|---:|
| Standard global entity-zero owner op | `0` | `1` | `0x01` |
| Selector-associated Grow op | `1` | `0` | `0x0100` (`256`) |

Nonce key `1` does not contain or overwrite entity `1`. It decodes as entity `0`
plus the global option. Entity `1` lives in the next four bytes and produces key
`0x0100`. EntryPoint maintains an independent 64-bit sequence for every key.

```mermaid
flowchart TD
    UO[UserOperation]
    Key["high 192-bit nonce key"]
    Decode["ValidationLocatorLib.loadFromNonce"]
    Owner{"decoded locator"}
    OwnerModule["entity 0 owner validator"]
    GrowModule["account-selected Grow entity"]

    UO --> Key --> Decode --> Owner
    Owner -->|key 0x01| OwnerModule
    Owner -->|key entityId << 8| GrowModule
```

Production code must query the complete nonce with:

```text
ownerNonce = EntryPoint.getNonce(account, 1)
growNonce  = EntryPoint.getNonce(account, uint192(growEntityId) << 8)
```

The module address is not prefixed to a v2.0.1 UserOperation signature. The nonce
already selected the validation storage entry. With no validation hooks, the complete
Grow signature is:

```text
0xFF || bytes65(growECDSASignature)
```

Alchemy strips the final sparse-segment marker and passes exactly 65 bytes to
`GrowYieldPolicyModule.validateUserOp`. The reference encoder is implemented in
[`grow-encoder.ts`](../script/ts/mav2-poc/grow-encoder.ts).

## Owner-authenticated onboarding and policy-owner rotation

```mermaid
sequenceDiagram
    participant O as Account owner(s)
    participant EP as EntryPoint
    participant A as Alchemy account
    participant P as Grow policy module
    participant X as Executor

    O->>EP: Owner-signed UserOp, nonce key 1
    EP->>A: validate via entity-0 global owner validator
    EP->>A: installValidation(Grow entity, executeBatch selector)
    A->>P: onInstall(abi.encode(entityId, policyOwners))
    P->>P: Store entity and policy-owner addresses under account

    O->>EP: Owner-signed configuration UserOp, nonce key 1
    EP->>A: execute(executor.setAdapterPolicy(...))
    A->>X: Set finite directional limits

    O->>EP: Later owner-signed rotation/revocation UserOp
    EP->>A: execute(policy.addOwner/removeOwner)
    A->>P: Update only this account's policy-owner set
```

Recommended install data is:

```text
abi.encode(
  growEntityId,
  address[] policyOwners
)
```

The account install call must use the same `growEntityId`. Preflight the account
loupe before choosing it. Alchemy rejects an already-occupied entity; Grow also fails
closed if the account passes a different entity during later validation. Grow stores
one entity per account and rejects a second installation; uninstall the old entity
before selecting a replacement so the account cannot retain stale dual registrations.

The account-owner path—not the Grow policy—must also set finite adapter limits. A
policy owner cannot authorize `installValidation`, owner management, policy
management, guardian actions, arbitrary `execute`, or an arbitrary `executeBatch`.

## Automated rebalance execution flow

```mermaid
sequenceDiagram
    participant B as Grow policy owner
    participant R as Bundler
    participant EP as EntryPoint v0.7
    participant A as Alchemy MA v2.0.1
    participant P as Grow policy
    participant X as Executor
    participant S as Source adapter
    participant D as Destination adapter

    B->>B: Quote redeem and destination deposit
    B->>B: Build REDEEM + PREVIOUS_OUTPUT DEPOSIT
    B->>B: Set absolute minAmountOut for both operations
    B->>EP: getNonce(account, entityId << 8)
    B->>B: Finalize gas, pinned paymaster, fees, calldata
    B->>B: Sign EIP-712 authorization(userOpHash)
    B->>R: Submit 0xFF || authorization
    R->>EP: handleOps
    EP->>A: validateUserOp
    A->>P: validateUserOp(entityId, op, hash), 65-byte segment
    P->>P: Check policy owner, sponsor, gas, fees, batch shape
    P-->>EP: success or signature failure
    EP->>A: executeUserOp then executeBatch
    A->>X: execute([redeem, deposit])
    X->>S: Redeem source position to account
    X->>X: Measure previous output
    X->>D: Deposit exactly previous output
    X-->>A: Measured outputs; idle underlying remains untouched
```

The policy owner should persist the `(account, entityId, nonce key, sequence)` it
submits, but EntryPoint remains the source of truth for the next nonce. It should
simulate the final signed UserOperation through the production bundler and stop
signing before key rotation. Because the module supplies no time range, an unsubmitted
authorization remains usable while its nonce is current and its owner is authorized.

## Revocation and incident response

Independent controls are available:

1. Remove a policy owner through the account-owner path.
2. Set one or both account adapter directions to zero.
3. Permanently pause new deposits deployment-wide through the risk guardian.
4. Uninstall the Grow validation entity through the owner path.
5. Stop sponsor approval at the pinned paymaster.

Keep redemptions enabled during venue incidents whenever the venue still permits an
exit. Neither local contracts nor the guardian can guarantee external liquidity,
solvency, or future gate access.

## Verification boundary

The suite executes install, policy configuration, entity-specific nonce selection,
final-segment signature parsing, sponsored validation, deposit, redemption,
reallocation, replay rejection, and policy-owner revocation against Alchemy's
pinned v2.0.1 `ModularAccount` source. It also includes unit, adversarial, invariant,
Halmos-oriented, and optional Base Aave / Euler / CapyFi fork tests.

Production still requires reviewed direct adapter bytecode, verified constructor
arguments, a non-token-charging sponsor, realistic per-token limits and output floors,
operational key rotation, and bundler simulation under the deployed chain's ERC-7562
rules.
