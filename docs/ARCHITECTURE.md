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
    Executor["GrowYieldExecutor"]
    Registry["GrowYieldAdapterRegistry\nappend-only, governance-owned"]
    Registrars["Protocol registrars\nregistry-pinned"]
    Guardian["Risk guardian"]
    Aave[AaveV3Adapter]
    Morpho[MorphoVaultV2Adapter]
    EulerEVK[EulerEVaultAdapter]
    EulerEarn[EulerEarnAdapter]
    Capy[CapyFiAdapter]
    Venues["Aave / Morpho / Euler / CapyFi"]
    Paymaster["Pinned sponsor paymaster"]

    Owners -->|install, select registry, configure, rotate, revoke| Account
    PolicyOwner -->|sign exact UserOp| Bundler
    Bundler --> EP
    Paymaster -->|sponsor| EP
    EP --> Account
    Account -->|validateUserOp| Policy
    Policy --> PolicyLib
    Account -->|execute| Executor
    Executor -->|account-selected| Registry
    Registry -->|venue authenticity at admission| Registrars
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
    Gov["Registry owner\nSafe / Timelock"] -->|addVaults| Registry
```

The layers are deliberately separate:

| Layer | Enforced property |
|---|---|
| Alchemy account | Selects the installed validation entity and applies selector scope |
| Policy module | Authenticates an account-scoped policy owner and constrains UserOp fields |
| Policy library | Accepts only one canonical shape: a single forwarded `executor.execute` call |
| Executor | Resolves the account's registry, pins recipients and amounts, checks output floors, budgets, and pauses |
| Registry | Admits factory-authenticated venues and fixes their directions, token pairs, and runtime code hashes |
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

The library accepts exactly one shape and nothing else:

```text
account.execute(executor, 0, executor.execute(Operation[]))
```

That is the whole policy. It is short because the executor, not the calldata around it, is
what makes the operations safe: `execute` pulls the source token from `msg.sender` and credits
every output back to `msg.sender`, so reaching it can only move the caller's own funds, into or
out of a venue the registry admitted.

Accounts therefore hold a **standing allowance** to the executor, granted once by the owner.
There is no approve/revoke bracket, because a standing allowance here is not exploitable: for
funds to leave account A, A must itself be `msg.sender` on `execute`, which already requires a
signature. An earlier design wrapped every batch in `approve(max) … approve(0)` to avoid the
allowance; that bought defense-in-depth against a hypothetical executor bug and cost a bespoke
calldata parser to police.

The library also does not decode or vet the operations, and could not usefully do so: ERC-7562
confines validation to account-associated storage, so it cannot read the registry, and every
check it could make locally — nonzero vault, nonzero source token, nonzero output floor, batch
size — the executor enforces on the same calldata moments later. Duplicating them would add a
second place for the invariant to drift.

What it does enforce: the target is the account's approved executor, no ether moves, the inner
selector is `execute`, and `callData` is byte-for-byte the canonical encoding of what was
inspected, so nothing can be padded onto a validated request at the sponsor's expense. Batch
size is capped by a calldata ceiling derived from the executor's own `MAX_OPS`, which is the
single source of truth for that bound.

### `GrowYieldExecutor`

Every operation is signed as the following static tuple:

```solidity
struct Operation {
    address vault;            // the venue, as its protocol keys it
    OperationKind kind;       // DEPOSIT or REDEEM
    address sourceToken;
    uint256 amount;
    AmountMode amountMode;    // EXACT, FULL_BALANCE, PREVIOUS_OUTPUT
    uint256 minAmountOut;     // absolute floor, signed by whoever authorized the operation
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

1. Resolves the venue from its immutable registry, then confirms the registry permits the
   direction, the adapter code hash matches, and deposits are not paused.
2. Re-derives source and output tokens and checks the signed source declaration.
3. Resolves the explicit amount mode.
4. Reads the adapter preview.
5. Transfers the exact source amount directly from the account to the adapter.
6. Invokes the adapter, which credits output directly to the account.
7. Rejects new residual balances or fee-on-transfer source behavior (one wei of
   rebasing-token rounding, e.g. aTokens, is tolerated).
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

### Executor–registry binding

The executor has **no owner** and no per-account configuration. It deploys its own registry
in its constructor, and the two name each other immutably:

```solidity
IGrowYieldAdapterRegistry public immutable registry;   // on the executor
address public immutable executor;                     // on the registry
```

Deploying the registry from the constructor is what makes the binding total. CREATE2 cannot
resolve a mutual pin — each contract's init code would have to contain the other's address —
so the alternatives are a settable slot or an initializer window. Creating the registry inline
has neither: nothing about the pair is configurable after deployment.

Which venues exist is therefore a single governance decision, made once by the registry owner
calling `addVaults`. There is no per-account registry selection and no per-account, per-venue
enablement to keep in sync with it.

The executor is permissionless as a result: `execute` pulls the source token from `msg.sender`
and credits every output back to `msg.sender`, so a caller can only ever move their own funds,
and only into or out of an admitted venue. Nothing is gained by calling it as anyone else.

### The account's opt-in

An account approves exactly one executor and one sponsoring paymaster, and it does so on the
**policy module**, not on the executor:

```solidity
function setExecutor(address executor) external;    // keyed by msg.sender
function setPaymaster(address paymaster) external;  // keyed by msg.sender
```

`onInstall(abi.encode(entityId, policyOwners, executor, paymaster))` is the account's whole
enrollment. The executor names the registry, the registry names the venues, and there is
nothing further to configure per venue.

`setExecutor` is load-bearing well beyond routing: once set, a policy owner can sign a call to
that address. So the module requires the candidate to prove it is a Grow executor bound to a
registry that names it back — a property no arbitrary contract can fake without deploying the
real pair. Otherwise an owner typo would become a session-key-exploitable drain.

The paymaster is per-account for availability, not security: a single protocol-wide immutable
sponsor would halt every account's automation the day it is retired or depleted, recoverable
only by reinstalling the module everywhere. Per-account, rotation is one owner signature.

Because `GrowYieldPolicyLib` accepts exactly one calldata shape and that shape is a single call
to the executor, **no policy-owner signature can ever produce a `setExecutor` or `setPaymaster`
call**. Both require the account's own owner-authorized validation path — the same path that
installs the module. Session keys and the Grow backend are excluded by construction.

Replacement is immediate and has no overlap: batches targeting the previous executor stop
validating the moment `setExecutor` returns. Exit positions opened through an executor before
replacing it. Since each executor is permanently bound to its own registry, this is also how
an account moves to a new admitted venue set — for example one that supports a new protocol.

An account with no approved executor validates nothing: `isAllowedCallData` returns false.

### What is deliberately *not* constrained

There are no per-account, per-venue volume limits, epochs, or directional budgets. A
policy-owner (session key) may move the account's full balance between admitted venues at
will. The remaining constraints are qualitative, not quantitative:

- output is credited only to the account, so funds cannot leave it;
- only admitted venues, only in admitted directions;
- every hop must clear the loss-capped preview floor and the signed absolute floor.

The residual exposure is **attrition**, not theft: a compromised session key can cycle
deposit → redeem → deposit and lose up to `maxLossBps` per hop on sponsor-paid gas. The risk
guardian's deposit pause is the only volume-side control, and owner-signed `removeOwner` is
the revocation path.

### Risk guardian and the reversible pause

The executor has one immutable `riskGuardian`. It, or the registry owner, can pause new
deposits into a venue for every caller at once. Only the **registry owner** can un-pause.

That split is the point: protecting is fast and unilateral, re-exposing accounts to a venue is
a governance decision. Neither authority can move funds, admit a venue, or block redemptions, so
a paused venue is one nobody can enter and everybody can leave. Letting governance pause as well
means protection does not depend on a single hot key, and letting it un-pause means a
false-positive pause is an ordinary operation rather than an unrecoverable state requiring a new
deployment.

The pause target must be a venue this executor's own registry admitted, so a mistyped address
reverts `VenueNotAllowed` rather than recording a pause that protects nothing.

Venues themselves are never delisted, deliberately. Removing an admitted venue would set
`canRedeem` false for accounts already holding its position token and trap them; the reversible
deposit pause is the delisting mechanism, and it leaves the exit open by construction.

### Trust boundary: authenticity vs Grow approval

Adapter constructor and per-operation protocol checks answer only:

> “Is this a genuine canonical deployment of the named protocol (Euler factory
> proxy / Earn vault / CapyFi listed market / Aave reserve / Morpho wrapper)?”

They do **not** answer:

> “Is this vault or market an acceptable Grow yield venue?”

That second decision is made solely by **the registry owner calling `addVaults`**. The
registry is Grow's approval and risk-admission layer: which venues exist, which directions
are enabled, and which runtime code hashes the executor will accept. A factory-authentic
Euler vault that is absent from the registry cannot be used. Conversely, admission without
passing the adapter's own authenticity checks fails closed at construction or execution.

The registry does **not** take the owner's word on authenticity. It re-derives the venue from
`IYieldAdapter.positionToken()` and asks its own constructor-pinned registrar, so admitting a
venue the protocol never created is impossible even for a compromised owner. Risk judgement
is delegated to the owner; provenance is not.

### `GrowYieldAdapterRegistry`

The registry is `Ownable2Step` and **append-only**. `addVaults` is its only writer: an
admitted entry's adapter, protocol, directions, code hash, and venue binding are never
mutated or removed. It records:

- Each adapter in admission order (`adapterCount` / `adapterAt`).
- Deposit and redeem permissions, plus the admitting protocol (`vaultProtocol`).
- Each adapter's admission-time runtime code hash.
- Each venue's position token → underlying binding.

The owner should be a Safe or TimelockController. Once the intended venue set is final the
owner may `renounceOwnership()`, making the registry fully immutable. There is no delisting
path: deposit-side wind-down is the risk guardian's permanent `pauseAdapterDeposits`, and any
account can zero its own directional limits, so no mutation can ever strip `canRedeem` and
trap an account in a position.

There is no lifetime vault ceiling. Nothing on-chain iterates the admitted set — `adapterAt`
and `adapterCount` are O(1) and no loop reads the whole array — so a cap would buy nothing and
would introduce a cliff at which a purely numeric limit, unrelated to protocol support, forces a
registry migration and a re-consent from every account. The venue count is bounded by governance
intent alone.

Proxies remain unsuitable as adapters: a proxy's runtime code hash can stay constant while
its implementation changes.

#### Constructor-pinned registrars

The registry pins one canonical registrar set per supported protocol, immutably:

| Field | Protocol | Used for |
|---|---|---|
| `aavePool`, `aaveDataProvider` | `AAVE` | Reserve lookup and adapter wiring |
| `morphoVaultFactory`, `morphoAdapterFactory`, `morphoEligibility` | `MORPHO` | Wrapper, liquidity-adapter, and child authentication |
| `eulerEVaultFactory` | `EULER_EVK` | EVault proxy authentication |
| `eulerEarnFactory` | `EULER_EARN` | Earn vault authentication |
| `capyFiComptroller` | `CAPYFI` | Market listing |

A zero address marks that protocol **unsupported by this registry**; `addVaults` rejects it
with `UnsupportedProtocol`. Aave requires both of its fields and Morpho all three — a
half-configured protocol reverts at construction rather than silently skipping part of its
authenticity proof. Every nonzero registrar must be a deployed contract.

Because the `Protocol` enum and its registrars are fixed at deployment, **supporting a new
protocol requires deploying a new registry** and having accounts reselect it. Adding another
vault for an already-supported protocol does not.

#### `addVaults` admission checks

Protocol-independent, for every entry:

| Check | Failure |
|---|---|
| Adapter is a deployed contract, and at least one direction is enabled | `Invalid` |
| Adapter not already registered (append-only) | `VaultAlreadyRegistered` |
| `IYieldAdapter.executor() == executor` | `Invalid` |
| `asset` and `positionToken` are deployed and distinct | `Invalid` |
| No registered adapter already holds this position token | `DuplicateVenue` |

Then, dispatched on the declared protocol — first that the adapter is wired to the registry's
own registrars (`RegistrarMismatch`), then that the registrar recognizes the venue
(`NotCanonicalVenue`):

| Protocol | Adapter wiring re-checked | Registrar proof over `positionToken()` |
|---|---|---|
| `AAVE` | `pool()`, `dataProvider()` | `getReserveTokensAddresses(asset()).aToken == positionToken()` |
| `MORPHO` | `eligibility()` | `isVaultV2(wrapper)`, `isMorphoVaultV1Adapter(liquidityAdapter())`, that adapter's `parentVault()`/`morphoVaultV1()` re-derive the wrapper and `child()`, and `isEligibleVault(child)` |
| `EULER_EVK` | `factory()` | `isProxy(vault)` |
| `EULER_EARN` | `factory()` | `isVault(vault)` |
| `CAPYFI` | `comptroller()` | `markets(caToken).isListed` |

The Morpho path deliberately re-derives routing from the liquidity adapter rather than
trusting the venue adapter's reported `child()`, so an eligible child cannot be claimed by a
wrapper that routes somewhere else. Every registrar call is `view`, hence a `STATICCALL`: an
adapter or registrar cannot mutate state or reenter during admission (and `addVaults` is
`onlyOwner`, so a reentrant call would fail on `msg.sender` anyway).

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

### Adding venues: what must be redeployed

| Change | What is required |
|---|---|
| New venue for an already-supported protocol | `addVaults` from the registry owner. The protocol's adapter already exists and serves every venue of that protocol, so nothing is redeployed and every account sees the venue immediately. |
| New **protocol** | Deploy a new executor pinning the additional registrar (it deploys its own registry), deploy adapters for it, `addVaults` the full intended set, then each account switches with one owner-signed `policy.setExecutor`. The policy module and the old stack are untouched. |
| Change to executor or policy-module logic | Full stack migration, as before: a new executor, new adapters pinned to it, a new registry, and a new policy-module install on each account. |

Adapters pin their executor, so a new executor requires new adapter deployments; the registrars
and venue addresses they are wired to do not change. Accounts that switch gain the whole new
venue set at once, which is the trade for having no per-account venue gate.

### Deployment procedure

`script/Deploy.s.sol` drives `GrowYieldDeployer.deployStack` from `script/config/<env>.json`.
One atomic transaction deploys the executor (which deploys its registry), the policy module,
and every adapter; admits the configured vault set; and offers registry ownership to
`.registry.owner`:

1. The executor's init code names the shared deployer as its registry's initial owner.
2. The deployer calls `addVaults` with the full configured set, then `transferOwnership`.
3. Governance calls `acceptOwnership()` in a later transaction.

The deployer can never admit vaults again: `deployStack` is its only function, and CREATE2
cannot reproduce the now-occupied stack addresses. It also rejects a `registryOwner` of zero
or itself, either of which would strand ownership with a contract that cannot call `addVaults`.

The script cross-checks every configured adapter's protocol addresses against
`.registry.registrars`, so an adapter wired to infrastructure the registry does not pin fails
the script rather than reverting on-chain. It also asserts post-deployment that the registry
pins the expected executor, admitted every configured vault with the expected code hash,
directions, and protocol, and is pending transfer to the configured owner.

Accounts are not enrolled by deployment. Each account enrolls itself with one owner-signed
`installValidation`, whose install data names the executor it approves.

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
    EP->>A: installValidation(Grow entity, execute selector)
    A->>P: onInstall(abi.encode(entityId, policyOwners, executor))
    P->>P: Store entity, policy owners, and approved executor under account
    Note over P,X: One transaction is the whole opt-in: the executor names<br/>the registry, the registry names the venues.

    O->>EP: Later owner-signed executor switch (new venue set)
    EP->>A: execute(policy.setExecutor(newExecutor))
    A->>P: Replace this account's approved executor

    O->>EP: Later owner-signed rotation/revocation UserOp
    EP->>A: execute(policy.addOwner/removeOwner)
    A->>P: Update only this account's policy-owner set
```

Recommended install data is:

```text
abi.encode(
  growEntityId,
  address[] policyOwners,
  address approvedExecutor
)
```

The account install call must use the same `growEntityId`. Preflight the account
loupe before choosing it. Alchemy rejects an already-occupied entity; Grow also fails
closed if the account passes a different entity during later validation. Grow stores
one entity per account and rejects a second installation; uninstall the old entity
before selecting a replacement so the account cannot retain stale dual registrations.

`approvedExecutor` completes enrollment in the same call: no follow-up configuration
transaction is required, and the account can never be left half-configured. A policy owner
cannot authorize `installValidation`, owner management, policy management, `setExecutor`,
guardian actions, `executeBatch`, or an `execute` aimed anywhere but the approved executor.

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
    P->>P: Check policy owner, sponsor, gas, fees, calldata shape
    P-->>EP: success or signature failure
    EP->>A: executeUserOp then execute
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

1. Remove a policy owner through the account-owner path (immediate, per account).
2. Uninstall the Grow validation entity through the owner path (immediate, per account).
3. Revoke the account's standing allowance to the executor through the owner path.
4. Pause a venue's deposits — guardian or registry owner, protocol-wide, reversible by the
   registry owner alone.
5. Stop sponsoring at the account's approved paymaster, or point the account at another one.

Controls 1 and 2 are the account-wide stops and take one owner-signed call. Control 4 is the
protocol-wide one. Nothing here can block a redemption, by design.

Keep redemptions enabled during venue incidents whenever the venue still permits an
exit. Neither local contracts nor the guardian can guarantee external liquidity,
solvency, or future gate access.

## Verification boundary

The suite executes install, owner-signed registry selection, policy configuration,
entity-specific nonce selection, final-segment signature parsing, sponsored validation,
deposit, redemption, reallocation, replay rejection, and policy-owner revocation against
Alchemy's pinned v2.0.1 `ModularAccount` source. It asserts end-to-end that a policy-owner
signature cannot retarget an account's registry, bare or wrapped in a batch, and that the
owner path can. It also includes unit, adversarial, invariant, Halmos-oriented, and optional
Base fork tests; the all-adapters fork test admits one live vault per protocol, exercising
every registrar dispatch against real Base deployments.

Production still requires reviewed direct adapter bytecode, verified constructor
arguments, a non-token-charging sponsor, realistic per-token limits and output floors,
operational key rotation, and bundler simulation under the deployed chain's ERC-7562
rules.
