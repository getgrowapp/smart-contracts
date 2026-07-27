# Change log

> **Superseding change — executor/registry coupling + policy simplification.**
> Sections 1–N below describe the *previous* refactor. Two of its decisions have since been
> reversed for simplicity:
>
> - **Per-account registry selection is gone.** The executor now deploys its own registry in
>   its constructor; `registry` and `executor` are immutable on both sides and nothing is
>   settable. `setAccountRegistry` / `accountRegistry` are removed.
> - **Per-account, per-venue epoch policy is gone.** `setVaultPolicy`, `resetVaultPolicy`,
>   `vaultPolicy`, directional volume limits, epochs, and the `BudgetExceeded` /
>   `UnboundedPolicy` / `EpochDurationChangeRequiresReset` errors are removed. Admission is
>   the only venue gate; the executor holds no per-account state and is permissionless.
> - **The account approves one executor, on the policy module.** Install data is now
>   `abi.encode(entityId, policyOwners, executor)`, and `policy.setExecutor` (owner path only)
>   replaces it. One signed transaction is the whole opt-in.
>
> Consequence to weigh: a compromised policy owner can move the account's full balance
> between admitted venues without a volume cap, bleeding up to `maxLossBps` per hop. Funds
> cannot leave the account. See "What is deliberately *not* constrained" in
> [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Previously: post-deployment vault admission + owner-signed registry selection

Replaces the constructor-fixed adapter registry with an append-only registry whose venues must
be authenticated by deployment-pinned protocol registrars, and moves the executor's single
global registry pointer to a per-account selection that only the smart account's own owner path
can change.

Design detail lives in [`ARCHITECTURE.md`](ARCHITECTURE.md); this file is the change summary.

## 1. Registry: constructor-fixed → append-only `addVaults`

`src/GrowYieldAdapterRegistry.sol`, `src/interfaces/IGrowYieldAdapterRegistry.sol`

**Before:** the full adapter set was passed to the constructor. There was no owner and no
mutation path; admitting any new venue required redeploying the registry *and* the executor.

**After:** `GrowYieldAdapterRegistry` is `Ownable2Step` with one writer:

```solidity
enum Protocol { AAVE, MORPHO, EULER_EVK, EULER_EARN, CAPYFI }

struct VaultConfig { address adapter; Protocol protocol; bool canDeposit; bool canRedeem; }

function addVaults(VaultConfig[] calldata vaults) external onlyOwner;
```

- **Append-only.** An admitted entry's adapter, protocol, directions, code hash, and venue
  binding are never mutated or removed. There is no `setAdapter`, no delist, no permission edit.
  Wind-down remains the risk guardian's permanent `pauseAdapterDeposits` plus the account's own
  ability to zero its directional limits — so no path can strip `canRedeem` and trap an account
  in a position.
- **Owner is governance** (Safe / TimelockController), declared in the constructor rather than
  captured from `msg.sender`. Once the venue set is final the owner may `renounceOwnership()`,
  restoring full immutability.
- **No lifetime vault ceiling.** The old `MAX_ADAPTERS` was dropped rather than raised: nothing
  on-chain iterates the admitted set (`adapterAt` / `adapterCount` are O(1)), so a cap protects
  nothing, while it would create a cliff at which a purely numeric limit — unrelated to protocol
  support — forces a registry migration and a re-consent from every account.
- Added `vaultProtocol(address)` for monitoring; entry order still readable via
  `adapterCount` / `adapterAt`. Event renamed `AdapterConfigured` → `VaultAdded` and carries
  the protocol.
- Replaced the write-only `positionToken → asset` mapping with a `positionToken → bool` set
  (the address value was stored but never read and had no getter).

### Registrars are constructor-pinned, and the registry proves provenance itself

The registry pins one canonical registrar set per protocol, immutably:

| Field(s) | Protocol |
|---|---|
| `aavePool`, `aaveDataProvider` | `AAVE` |
| `morphoVaultFactory`, `morphoAdapterFactory`, `morphoEligibility` | `MORPHO` |
| `eulerEVaultFactory` | `EULER_EVK` |
| `eulerEarnFactory` | `EULER_EARN` |
| `capyFiComptroller` | `CAPYFI` |

A zero address marks the protocol unsupported by that registry (`UnsupportedProtocol`). Aave
requires both fields and Morpho all three — a half-configured protocol reverts at construction
rather than silently skipping part of its authenticity proof. Every nonzero registrar must be a
deployed contract.

Because the enum and its registrars are fixed at deployment, **supporting a new protocol
requires deploying a new registry.** Adding another vault for an already-supported protocol
does not.

`addVaults` does **not** take the owner's word on provenance. Per entry it runs the
protocol-independent checks (deployed adapter, at least one direction, not already registered,
`IYieldAdapter.executor() == executor`, deployed and distinct `asset`/`positionToken`, unique
position token), then dispatches on the declared protocol: first that the adapter is wired to
the registry's *own* registrars (`RegistrarMismatch`), then that the registrar recognizes the
venue derived from `positionToken()` (`NotCanonicalVenue`).

| Protocol | Adapter wiring re-checked | Registrar proof |
|---|---|---|
| `AAVE` | `pool()`, `dataProvider()` | `getReserveTokensAddresses(asset()).aToken == positionToken()` |
| `MORPHO` | `eligibility()` | `isVaultV2(wrapper)`; `isMorphoVaultV1Adapter(liquidityAdapter())`; that adapter's `parentVault()` / `morphoVaultV1()` re-derive the wrapper and `child()`; `isEligibleVault(child)` |
| `EULER_EVK` | `factory()` | `isProxy(vault)` |
| `EULER_EARN` | `factory()` | `isVault(vault)` |
| `CAPYFI` | `comptroller()` | `markets(caToken).isListed` |

Consequence: a compromised registry owner can admit a *bad-risk* venue, but not a venue the
protocol never created. Risk judgement is delegated; provenance is not. The Morpho path
deliberately re-derives routing from the liquidity adapter instead of trusting the adapter's
reported `child()`, so an eligible child cannot be claimed by a wrapper that routes elsewhere.

Every registrar call is `view`, hence `STATICCALL`: an adapter or registrar cannot mutate state
or reenter during admission (and `onlyOwner` would reject a reentrant call regardless).

New errors: `EmptyBatch`, `UnsupportedProtocol`, `RegistrarMismatch`, `NotCanonicalVenue`,
`VaultAlreadyRegistered`, `DuplicateVenue` — replacing the single `Invalid` for these cases so an
admission failure is actionable. New `src/interfaces/IAdapterVenue.sol` declares the adapter
getters the registry reads.

## 2. Executor: global registry → per-account, owner-signed selection

`src/GrowYieldExecutor.sol`, `src/interfaces/IGrowYieldExecutor.sol`

**Before:** one global `registry`, attached once by the executor owner via `initializeRegistry`,
never changeable.

**After:**

```solidity
mapping(address account => IGrowYieldAdapterRegistry) public accountRegistry;

function setAccountRegistry(IGrowYieldAdapterRegistry registry_) external;
```

- **Keyed by `msg.sender`**, so only the smart account can change its own selection. Because
  `GrowYieldPolicyLib` accepts exactly one batch shape — `approve` / `executor.execute` /
  `approve` — **no policy-owner (session key or backend admin) signature can produce this
  call.** Changing the registry requires the account's own owner-authorized validation path,
  the same one that installs the module and sets adapter limits. No new signature scheme, no new
  privileged role, no widening of the policy library's accepted calldata.
- **Validation:** deployed contract, `executor() == address(this)`, and at least one admitted
  vault. The last condition rejects two silent mistakes at selection time rather than at the
  first operation — an adapter address (adapters also report `executor()`) and an empty registry
  no operation could use. Registries are append-only, so a registry that satisfies it cannot
  stop satisfying it.
- **Reselection is permitted** and is the venue-expansion path: governance deploys a registry
  supporting a new protocol; each account opts in with one owner-signed call. Reselection
  re-gates execution immediately (an adapter absent from the new registry reverts
  `AdapterNotAllowed`).
- **Per-adapter limits survive reselection, deliberately.** Admission and limits are independent
  gates: an operation needs the registry to permit the direction *and* the account to hold a
  nonzero limit for it. A new registry therefore can never silently enable a venue the account
  has not separately authorized, so invalidating limits on every expansion would cost every
  user a full re-onboarding for no security gain.
- `execute` resolves the registry **once per batch** — cheaper than the previous per-operation
  SLOAD, and a reentrant reselection cannot change the rules applied to an in-flight batch
  (`execute` is `nonReentrant` regardless).
- **The executor is now ownerless.** `initializeRegistry` was its only `onlyOwner` function, so
  `Ownable2Step` was removed rather than left as a dead, misleading privilege visible in
  explorers. Every configuration decision now belongs to the account (its registry, its limits)
  or to the immutable risk guardian.
- `pauseAdapterDeposits` no longer checks registry membership (there is no single registry to
  check). It requires the target to authorize this executor, so a mistyped address reverts
  `AdapterNotAllowed` instead of recording a pause that protects nothing. The guardian's power
  is otherwise unchanged: deposits only, all accounts and registries, never redemptions.
- `Uninitialized` → `RegistryNotSet` (semantics changed from global to per-account);
  `RegistryAlreadyInitialized` and `RegistryInitialized` removed; `AccountRegistrySet` added.

### Onboarding order change

The account owner path must now call `setAccountRegistry` **before** `setAdapterPolicy`
(otherwise `RegistryNotSet`). Deployment enrolls nobody.

## 3. Deployment

`script/GrowYieldDeployer.sol`, `script/Deploy.s.sol`, `script/config/*.json`

`deployStack` takes a single `StackParams` struct and, in one atomic transaction: deploys the
executor, policy module, every adapter, and the registry (declaring itself the registry's
initial owner); calls `addVaults` with the configured set; verifies each vault landed; then
`transferOwnership` to the configured governance address, which accepts in a later transaction.

The deployer can never admit vaults again — `deployStack` is its only function and CREATE2
cannot reproduce the now-occupied stack addresses. It rejects a `registryOwner` of zero or
itself, either of which would strand ownership with a contract that cannot call `addVaults`.
It no longer needs or takes executor ownership.

Config gains `.registry.owner` and `.registry.registrars.*`. The script cross-checks every
configured adapter's protocol addresses against the pinned registrars, so an adapter wired to
infrastructure the registry does not pin fails the script instead of reverting on-chain. It
asserts post-deployment that the registry pins the expected executor, admitted every configured
vault with the expected code hash / directions / protocol, and is pending transfer to the
configured owner. The artifact records `registryPendingOwner`.

## 4. Tests

185 passing, including every Base fork suite. New coverage:

- `test/yield/GrowYieldRegistryAdmission.t.sol` (17 tests): the full dispatch matrix — an
  authentic venue admitted for all five protocols; `UnsupportedProtocol` for each zeroed
  registrar; `RegistrarMismatch` for foreign pool / data provider / eligibility / factories /
  comptroller; `NotCanonicalVenue` for unlisted Aave reserves, aToken mismatch, non-factory
  Morpho wrapper, non-factory liquidity adapter, routing that contradicts the claimed child,
  ineligible child, unregistered Euler vaults, a vault delisted after adapter deployment, and
  unlisted CapyFi markets. Backed by a new `MockRogueVenueAdapter` that reports fully
  attacker-chosen wiring, standing in for an adapter a compromised owner could deploy.
- `GrowYieldExecutor.t.sol`: `RegistryNotSet` on execute/configure; per-account, self-keyed
  selection; rejection of an EOA, a foreign-executor registry, an adapter, and an empty
  registry; reselection re-gating venues while limits survive; guardian pause rejecting foreign
  and mistyped targets.
- `GrowYieldE2E.t.sol`: the owner path selects the registry during onboarding, and a
  policy-owner signature cannot retarget it — bare (no validation function for that selector)
  or wrapped in a batch (`AA24 signature error`) — while the owner path can.
- `GrowYieldAdapters.t.sol`: `onlyOwner`, empty batch, re-admission within and across batches,
  duplicate venue, conflicting asset/position pair, foreign registrar, unrecognized venue,
  half-configured and non-contract registrars, and 40 vaults admitted across separate batches
  with no ceiling.
- `Deploy.t.sol`: vault admission plus ownership handover, the deployer's inability to admit
  vaults afterwards, and rejection of unusable registry owners.
- `GrowYieldInvariants.t.sol`: under fuzzing, no operation path admits a vault, edits an
  admitted entry, or retargets the account's registry.

Registry branch coverage 33% → 91%.

Test mocks: `MockAavePool` and `MockMutableAaveDataProvider` now serve multiple reserves, so one
pool / provider pair backs several adapters — matching real Aave topology, which the registry's
single pinned pair now requires.

## Not changed

`GrowYieldPolicyModule`, `GrowYieldPolicyLib`, and every adapter are untouched. The module still
pins its executor immutably, and the policy library's accepted calldata shape is unchanged —
that unchanged shape is exactly what keeps session keys away from `setAccountRegistry`.

## Noted, not touched (pre-existing)

- `MockAaveDataProvider` in `test/invariant/MockYieldVenues.sol` is unreferenced dead code.
- `ARCHITECTURE.md` links `ADAPTER-DEPLOYMENT-MATRIX.md`, which does not exist.
