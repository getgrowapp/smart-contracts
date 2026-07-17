# GrowYield policy module — ready for audit

GrowYield is a selector-associated ERC-6900 validation module and constrained yield
executor for Alchemy Modular Account v2. The integration suite runs against the
actual Alchemy `ModularAccount` source at tag `v2.0.1` (commit `efab648`).

The code is ready for independent review, not production approval. Production still
requires audited direct-adapter bytecode, verified deployment parameters, realistic
per-account limits and output floors, and simulation through the target bundler.

The complete architecture, contract catalogue, diagrams, entity routing, onboarding,
and rebalance flow are in
[`docs/VALIDATION-MODULE-ARCHITECTURE.md`](docs/VALIDATION-MODULE-ARCHITECTURE.md).

## Architecture

```text
Account owner validation
  └─ install/configure/revoke Grow entity and adapter policies

Grow policy owner
  └─ sponsor-paid UserOp selected by Grow entity nonce key
       └─ GrowYieldPolicyModule
            ├─ account-scoped owner authorization
            ├─ immutable gas/fee/paymaster bounds
            └─ canonical approve/execute/revoke batch policy

GrowYieldExecutorV3
  ├─ account-owned finite directional epoch limits
  ├─ explicit EXACT / FULL_BALANCE / PREVIOUS_OUTPUT modes
  ├─ preview-relative and signed absolute output floors
  ├─ permanent guardian deposit pause; redemptions remain open
  └─ constructor-fixed registry → direct Aave/Morpho adapters
```

The account's ordinary owner validator and Grow are separate validation entities.
For pinned Modular Account v2.0.1, the high 192-bit EntryPoint nonce key selects the
validation:

| Path | Example entity | Nonce key |
|---|---:|---:|
| Global entity-zero owner validator | `0` | `1` |
| Selector-associated Grow validator | `1` | `0x100` (`1 << 8`) |

Nonce key `1` does **not** mean entity `1` and does not overwrite it. It decodes as
entity `0` plus the global-validation option bit. Grow's entity is account-selected;
preflight the account's installed validations instead of assuming entity `1` is free.

## Core security properties

- Only canonical `executeBatch` calldata is accepted: approve source tokens to the
  fixed executor, execute up to four operations, then reset every approval to zero.
- A Grow policy owner cannot install modules, manage owners, change limits, choose
  arbitrary recipients, call arbitrary targets, or charge EntryPoint prefund to the account.
- Policy owners are account-scoped and can be added or revoked only through the
  smart account's ordinary owner-authorized path.
- Every operation declares a source token, an explicit amount mode, and a nonzero
  absolute `minAmountOut`; the executor independently verifies all three.
- `PREVIOUS_OUTPUT` reallocates only the immediately preceding measured output, so a
  rebalance does not sweep unrelated idle underlying from the account.
- Adapter policies are finite source-token volumes per direction and epoch.
  `type(uint256).max` is rejected because it would make the quantitative control
  meaningless. Updating limits preserves consumption; resetting usage is explicit.
- The immutable risk guardian can permanently stop new deposits through a registered
  adapter, but cannot unpause, move funds, change policy, or block redemptions.
- The registry is constructor-fixed, enumerable, and code-hash pinned. Production
  adapters must be direct deployments rather than upgradeable proxies.
- Fee-on-transfer source tokens, zero output, excessive shortfall, adapter residuals,
  code drift, and reentrancy fail closed.

These controls do not guarantee venue solvency, liquidity, governance behavior, or
future exit permission. A compromised policy owner can deliberately consume the full
owner-configured budget at a bad time.

## Owner-authenticated installation

Choose a free nonzero `growEntityId`, then use the normal owner-authorized account
path to install Grow for `executeBatch` only:

- `isGlobal = false`
- `isSignatureValidation = false`
- `isUserOpValidation = true`
- selectors: `[IModularAccount.executeBatch.selector]`
- install data: `abi.encode(growEntityId, address[] initialOwners)`

One Grow entity is supported per account. Uninstall the existing entity before
installing a replacement, which prevents stale dual-entity registrations.

The owner must then call `setAdapterPolicy` with finite deposit/redeem limits for
each enabled adapter. Later account-owner operations can add or remove policy owners,
reduce limits to zero, or uninstall the Grow entity.

With no Grow validation hooks, the complete pinned-v2 UserOperation signature is:

```text
0xFF || bytes65(policyOwnerECDSASignature)
```

The policy owner signs the EIP-712
`GrowYieldAuthorization(userOpHash)` digest. The account's multi-owner
validator controls the independent owner signature format; it does not alter Grow's
entity routing or payload. See the
[`grow-encoder.ts`](script/ts/mav2-poc/grow-encoder.ts) reference helpers.

The module does not impose an authorization expiry. An unsubmitted signed operation
remains usable while its nonce is current and the policy owner remains authorized;
incident procedures must revoke the owner or invalidate the nonce.

## Deployment

1. Deploy `GrowYieldExecutorV3(maxLossBps, riskGuardian)` and
   `GrowYieldPolicyModule` with `DeployGrowYieldV3.s.sol`.
2. Deploy every executor-pinned direct adapter with `DeployAdapters.s.sol`.
3. Deploy the complete fixed registry and call the executor's one-time
   `initializeRegistry` from the original executor deployer.
4. Verify all bytecode, constructor parameters, registry enumeration, and code hashes
   before any owner installs the module.

Required production configuration includes `RISK_GUARDIAN`, `REQUIRED_PAYMASTER`,
finite gas/fee ceilings, and `MAX_LOSS_BPS` no greater than 100.

## Repository map

| Path | Purpose |
|---|---|
| `src/yield-1271/GrowYieldPolicyModule.sol` | Policy-owner authentication and UserOp constraints |
| `src/yield-1271/GrowYieldPolicyLib.sol` | Canonical batch policy |
| `src/yield-1271/GrowYieldExecutorV3.sol` | Amount, budget, output, and incident controls |
| `src/yield-1271/GrowYieldAdapterRegistry.sol` | Constructor-fixed adapter admission |
| `src/yield-1271/adapters/` | Aave V3 and Morpho VaultV2 integrations |
| `test/yield-1271/` | Unit, adversarial, invariant, EntryPoint, fork, and Halmos tests |
| `script/` | Core, adapter, and fixed-registry deployment scripts |

## Build and test

```bash
git submodule update --init
forge fmt --check
forge build --sizes
forge test -vv
forge lint
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract Fork -vv
```

Dependencies are exact git submodule pins under `lib/`; see
[`DEPENDENCIES.md`](DEPENDENCIES.md). Solidity is pinned to 0.8.36 with Cancun EVM
semantics.

The earlier Base EIP-1271 beta used removed contracts and is not an instance of this
architecture. Historical deployment data remains in `docs/BETA-FREEZE-REPORT.md`.
