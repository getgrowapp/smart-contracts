# GrowYield1271 — Ready for Audit

EIP-1271 yield automation policy (Alchemy Modular Account v2) for external review.

This is a **Foundry workspace**. Clone, then `forge build` / `forge test`.

## Architecture (adapter-based, V3/V4)

Protocol-specific logic lives behind a uniform `IYieldAdapter` interface (mirroring
Morpho VaultV2's own `IAdapter` pattern), so the executor and the EIP-1271 policy
signer never branch on protocol:

```
smart account (Alchemy MA v2)
  └─ SingleSignerValidationModule (pinned address)
       └─ GrowYield1271PolicySignerV4.isValidSignature   ── static calldata policy
            └─ GrowYieldPolicyLib: canonical batch =
                 [approve(token_i, max) …, executor.execute(ops), approve(token_i, 0) …]
executor.execute(Operation[] {adapter, kind, amount})     ── execution-time invariants
  └─ GrowYieldAdapterRegistry (owner allowlist, per-direction)
  └─ AaveV3Adapter / MorphoVaultV2Adapter / future venues
```

- **Signer** verifies authorization (shape): selectors, targets, approval bracketing,
  source-token binding, adapter allowlist. Runs before execution; cannot see outcomes.
- **Executor** verifies outcomes: exact-amount receipt (fee-on-transfer fails closed),
  loss cap vs adapter preview (`maxLossBps`), receiver hard-pinned to `msg.sender`
  (no recipient field exists in the ABI), zero residual on executor/adapters,
  transient-storage reentrancy guard.
- **Adapters** carry protocol knowledge: venue config validation at construction,
  drift re-checks on deposit (fail closed), exits never drift-gated (fail open).
- `Operation.amount` supports granular amounts; `type(uint256).max` = full balance.

## Scope

| Path | What |
|---|---|
| `src/yield-1271/IGrowYield1271.sol` | Types + `IYieldAdapter` / registry / executor interfaces |
| `src/yield-1271/GrowYieldExecutorV3.sol` | Generic operation executor |
| `src/yield-1271/GrowYieldAdapterRegistry.sol` | Owner-governed adapter allowlist |
| `src/yield-1271/GrowYield1271PolicySignerV4.sol` | EIP-1271 policy signer (module-pinned) |
| `src/yield-1271/GrowYieldPolicyLib.sol` | Canonical batch calldata policy |
| `src/yield-1271/GrowUserOpHashLib.sol` | ERC-4337 v0.7 userOp hashing (deliberate pin) |
| `src/yield-1271/adapters/` | `AaveV3Adapter`, `MorphoVaultV2Adapter` |
| `src/interfaces/` | Aave / Morpho eligibility ABIs used by adapters |
| `test/yield-1271/` | Unit / adversarial / invariant / fork / Halmos tests |
| `script/` | Deploy scripts |

Out of scope: Grow mobile/backend application code.

## Previous beta deployment (Base 8453) — superseded by this rewrite

The V2 executor / V3 signer / V6 registry below remain live on-chain but are removed
from this codebase (git history has the sources). The adapter stack in this repo is
not yet deployed.

| Component | Address |
|---|---|
| Registry (`GrowYieldRegistryV6`) | `0x7F219F5009Df002307Cf759994a1370De3d089E0` |
| Executor (`GrowYieldExecutor1271V2`) | `0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE` |
| Beta PolicySigner (`V3`) | `0xF2f02Ca6632EECb9232D3270fccF93D7b002c722` |

## Setup

```bash
git clone git@github.com:grow-app-prototype/GrowYield1271-Ready-for-Audit.git
cd GrowYield1271-Ready-for-Audit
git submodule update --init   # top-level only; nested submodules not needed
forge build
forge test -vv
# Fork tests (Base): BASE_RPC_URL=https://mainnet.base.org forge test --match-contract Fork -vv
# Symbolic: halmos --contract GrowYield1271HalmosTest
```

Dependencies are **git submodules under `lib/`**, pinned to exact commits — see
`DEPENDENCIES.md` for versions and rationale (`.gitmodules` carries per-pin notes;
`account-abstraction` is deliberately held at v0.7.0). Remappings: `foundry.toml` /
`remappings.txt`. solc is pinned to 0.8.36, `evm_version = cancun`.
