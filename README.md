# GrowYield1271 — Ready for Audit

EIP-1271 yield automation policy (Alchemy Modular Account v2) freeze for external review.

This is a **Foundry workspace**. Clone, then `forge build` / `forge test`.

## Freeze

- Monorepo freeze commit: `90022288030eb903917526d2cbd1275e86557ad5` (see `FREEZE.txt`)
- Beta report: `docs/BETA-FREEZE-REPORT.md`

## Scope

| Path | What |
|---|---|
| `src/yield-1271/` | PolicySigner V3, Executor V2, policy/userOp libs |
| `src/yield-v6/GrowYieldRegistryV6.sol` | Live registry impl at Base `0x7F219F…089E0` |
| `src/yield-v6/IGrowYieldSystem.sol` | Shared interfaces (`IGrowYieldRegistry`, etc.) |
| `src/interfaces/` | Aave / Morpho eligibility ABIs used by registry + executor |
| `test/yield-1271/` | Unit / adversarial / invariant / fork / Halmos tests |
| `script/` | Deploy scripts |

Out of scope: Grow mobile/backend application code.

## Deployed (Base 8453)

See `FREEZE.txt` and `docs/yield-v6-base-deployment.md`.

| Component | Address |
|---|---|
| Registry (`GrowYieldRegistryV6`) | `0x7F219F5009Df002307Cf759994a1370De3d089E0` |
| Executor | `0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE` |
| Beta PolicySigner | `0xF2f02Ca6632EECb9232D3270fccF93D7b002c722` |

## Setup

```bash
git clone git@github.com:grow-app-prototype/GrowYield1271-Ready-for-Audit.git
cd GrowYield1271-Ready-for-Audit
forge build
forge test --match-path 'test/yield-1271/*' -vv
```

Pinned dependencies are **vendored under `lib/`** (see `DEPENDENCIES.md`) so a fresh clone compiles without submodule fetch. Remappings: `foundry.toml` / `remappings.txt`.
