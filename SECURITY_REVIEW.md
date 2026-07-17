# GrowYield security review

This review covers the contracts, deployment scripts, Alchemy Modular Account v2.0.1
integration, and Aave V3/Morpho VaultV2 trust boundaries. It records the repository's
current controls and residual risks; it is not a substitute for an independent audit.

## Executive assessment

Grow policy-owner authority is intentionally narrower than smart-account-owner
authority. A policy owner can authorize only canonical, sponsor-paid yield batches
inside account-owned adapter budgets and per-operation output floors. It cannot
install or upgrade modules, manage policy owners, configure budgets, select an
arbitrary recipient, omit the pinned sponsor, or exceed immutable gas ceilings.

The local contracts cannot guarantee external venue solvency, liquidity, governance,
or future exit permission. A compromised policy owner can consume the full configured
budget at the least favorable permitted time and place it into any account-enabled
adapter. Production limits therefore need to represent loss/exposure the owner is
prepared to tolerate without an interactive signature.

## Authority and impact

| Principal | Capability and impact |
|---|---|
| Grow policy owner | Signs canonical rebalances within existing limits. Has no configuration or recipient authority. |
| Smart-account owner validation | Installs/uninstalls Grow, adds/removes policy owners, and sets/resets adapter policies through normal owner-authorized account execution. |
| Risk guardian | Permanently pauses new deposits through one registered adapter deployment-wide. Cannot unpause, block redemptions, move funds, or alter policy. |
| Registry initializer | Attaches one complete constructor-fixed registry to the executor. Has no authority after attachment. |
| Sponsor paymaster | Pays Grow UserOperation gas. Refusal stops automation but does not grant a token path. It must not charge the account in tokens. |
| Venue governance | Can change protocol behavior, upgrades, liquidity, fees, gates, and reserve state outside the local trust boundary. |

## Validation and account integration

### Exact account release and entity selection

The end-to-end suite imports Alchemy `ModularAccount` tag `v2.0.1`, commit
`efab648bd91f79685571af7fa88171e3c142f2f6`, and executes through EntryPoint v0.7.
It tests installation, nonce routing, sparse final-signature framing, sponsor payment,
replay rejection, policy-owner rotation, and the complete rebalance path.

Alchemy v2.0.1 derives the validation lookup from the high 192-bit nonce key:

```text
global entity-zero owner key = 1
selector-associated entity N key = uint192(N) << 8
```

Thus key `1` selects entity `0` with the global option bit; it does not select or
overwrite entity `1`. An example Grow entity `1` uses key `0x100`. The owner must
preflight the account's installed validations and select a free nonzero entity rather
than treating `1` as universally reserved. Grow permits one configured entity per
account and requires uninstalling it before a replacement can be installed.

The compatibility test uses a local single-owner harness for the ordinary owner
validator. A production multi-owner validator determines how the independent owner
signature is aggregated; it does not change Grow's nonce locator or 65-byte module
payload. Alchemy's older v1 MultiOwner MSCA/plugin product is a different account
generation and is outside this v2.0.1 framing claim.

### ERC-7562 validation behavior

`GrowYieldPolicyModule.validateUserOp` uses only ECDSA recovery, immutable fields,
calldata, and account-associated storage. It does not call the registry, tokens, or
venues and does not read `block.timestamp`. It returns no ERC-4337 time range.

Each account occupies nine associated storage slots: one packed entity/count slot and
eight fixed owner slots. This remains inside ERC-7562's associated-storage range and
avoids a global owner list whose mutation could invalidate unrelated accounts.

Malformed ABI is contained by an external self-call and maps to signature failure.
Calldata is capped at 7,000 bytes, `paymasterAndData` at 512 bytes, `initCode` must be
empty, and the final module payload must be exactly 65 bytes. The only policy-owner
proof is a low-`s` ECDSA signature over EIP-712
`GrowYieldAuthorization(userOpHash)`.

There is no module-enforced expiry or activation time. A signed operation remains
usable while its exact nonce is current and its policy owner remains authorized.
Revocation or nonce invalidation is therefore required to invalidate an outstanding
authorization that was never submitted.

Reference: [ERC-7562 validation rules](https://eips.ethereum.org/EIPS/eip-7562).

### Sponsor and gas extraction controls

The module requires a constructor-pinned paymaster and caps account verification gas,
call gas, pre-verification gas, paymaster verification/post-op gas, max priority fee,
and max fee. A missing or substituted paymaster fails validation, preventing Grow
operations from charging EntryPoint prefund to the account.

The sponsor remains an availability dependency. It must not use a token-charging
flow or rely on allowances from the smart account, and its production validation
logic requires a separate review.

## Execution controls

### Canonical call policy

`GrowYieldPolicyLib` accepts only `executeBatch` containing:

1. one max approval to the fixed executor for each unique source token;
2. exactly one `executor.execute(Operation[])` call; and
3. one zero-approval cleanup for each source token in the same order.

It rejects value, arbitrary targets, noncanonical ABI, self-calls, extra bytes, more
than four operations, mismatched source tokens, invalid amount modes, and a zero
absolute output floor. The executor independently repeats economically important
checks.

### Amount resolution and rebalancing

Operations use one explicit mode:

- `EXACT`: the signed nonzero amount;
- `FULL_BALANCE`: the current account balance of the verified source token; or
- `PREVIOUS_OUTPUT`: only the immediately preceding operation's measured output,
  requiring the next source token to match.

Rebalances use `REDEEM` followed by `PREVIOUS_OUTPUT DEPOSIT`. This prevents idle
underlying already held by the smart account from being swept into the destination
venue. `FULL_BALANCE` remains an explicit policy-owner choice for standalone
operations.

### Output protection

Every operation must satisfy both:

```text
ceil(adapterPreview * (10_000 - maxLossBps) / 10_000)
operation.minAmountOut
```

The larger floor is enforced against the account's measured balance increase. The
preview-relative check catches unexpected venue behavior; the independently quoted,
signed absolute floor limits reliance on the adapter's own preview. An adapter that
is malicious by construction can still lie and redirect funds, so registry admission
and direct bytecode review remain critical.

### Finite adapter budgets

Each account owns deposit and redeem source-volume limits per adapter and epoch. The
executor consumes budget before external calls; a revert rolls state back.

`setAdapterPolicy` changes limits without clearing spent volume. It rejects epoch
duration changes that would silently alter accounting. `resetAdapterPolicy` is the
explicit path that starts a fresh epoch and emits a reset event.

`type(uint256).max` is rejected. Such a limit is technically finite in the EVM but
practically unreachable, so it would disable the policy's quantitative protection.
Zero disables a direction; both limits at zero revoke the adapter for that account.

### Adapter admission and incident response

`GrowYieldAdapterRegistry` writes configuration only in its constructor. It has no
owner, setter, upgrade function, or disable switch. It validates executor binding,
token pairs, directions, and runtime code hash, and exposes enumeration for monitoring.
The executor checks the code hash on every operation.

Code-hash pinning does not make proxies safe: proxy runtime can remain constant while
the implementation changes. Only reviewed direct adapters should be admitted.

The immutable guardian's pause is one-way and deposit-only. It provides a fast
deployment-wide containment tool while leaving supported exits open. A mistaken or
compromised pause cannot steal funds but permanently removes the adapter as a deposit
destination; recovery requires a new stack and owner-approved migration.

### Token routing and adapter outcomes

- Source tokens are declared, re-derived from the adapter, and checked by the executor.
- Operations contain no recipient; adapters credit output only to `msg.sender`, the
  smart account.
- Exact source receipt rejects fee-on-transfer behavior.
- New adapter source/output residual balances are forbidden.
- Aave redemptions withdraw the exact attributed amount rather than the venue's max
  sentinel, so pre-existing adapter donations are not gifted to a later redeemer.
- The transient reentrancy guard spans the complete multi-operation batch.

## External and residual risks

### Venue changes can impair exits

Before a Morpho deposit, the adapter verifies current wrapper/child authenticity,
liquidity routing, abdication state, and gates needed for a round trip. Redemptions
re-check applicable exit gates. Governance can still change gates after deposit,
underlying liquidity can disappear, or the vault can lose value.

The Aave adapter re-checks the reserve's aToken before deposits. Aave upgrades,
reserve controls, insolvency, or unavailable liquidity can still impair withdrawals.

### No arbitrary emergency migration

The guardian cannot redeem positions or direct funds elsewhere. This avoids giving a
central role custody-like power, but it means smart-account owners or an authorized
policy owner must execute exits. Sponsor outage or unavailable owners can delay
response even though redemptions remain contractually enabled.

### Absolute floors require reliable quotes

An incorrectly high floor causes harmless liveness failure; an incorrectly low floor
weakens economic protection. The policy owner needs independent venue/market quotes,
decimal-aware bounds, final-UserOp simulation, and monitoring of both signed and
actual output.

## Production checklist

- Pin and verify Alchemy Modular Account v2.0.1, EntryPoint v0.7, the owner validator,
  Grow contracts, sponsor, and policy-owner encoder used in production.
- Query installed validations and choose a free nonzero Grow entity.
- Install Grow only for `executeBatch` with UserOperation validation enabled and
  global/runtime/signature validation disabled.
- Encode install data as `abi.encode(entityId, address[] policyOwners)`.
- Set finite, decimal-aware adapter limits through an owner-authorized operation.
- Use `PREVIOUS_OUTPUT` for the deposit leg of a rebalance and a nonzero independent
  `minAmountOut` on every operation.
- Verify direct-adapter bytecode, constructor arguments, registry enumeration, token
  pairs, directions, and code hashes.
- Use a non-token-charging sponsor and trace the final signed operation under the
  production bundler's ERC-7562 rules.
- Monitor policy-owner authorization, outstanding signatures, remaining budgets,
  guardian pause events, venue upgrades, gates, liquidity, and sponsor availability.
- Exercise policy-owner removal, zero-limit revocation, deposit pause, module
  uninstall, and owner-only emergency redemption before launch.

## Verification coverage

The suite covers direct validation and malformed inputs, policy-owner lifecycle,
account storage isolation, exact Alchemy nonce routing and signature framing,
EntryPoint replay rejection, sponsor payment, gas-cap rejection, canonical policy
rejection, fixed-registry construction and enumeration, budget preservation/reset,
absolute floors, all amount modes, idle-balance isolation, guardian pause behavior,
malicious/unregistered adapters, token behavior, venue drift/gates, stateful
invariants, optional Base Aave fork behavior, and Halmos-oriented properties.
