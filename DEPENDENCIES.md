# Dependency pins

Dependencies are git submodules under `lib/`, pinned by gitlink. After cloning:

```bash
git submodule update --init
```

Nested dependency submodules are not required. CI pins Foundry v1.7.1; the contract
toolchain is pinned to Solidity 0.8.36 and Cancun EVM semantics. Cancun transient
storage is used by the executor's reentrancy guard.

## Compile and integration graph

| Library | Exact pin | Purpose and rationale |
|---|---|---|
| `forge-std` | v1.16.2 (`bf647bd`) | Foundry tests and deployment scripts |
| `openzeppelin-contracts` | v5.6.1 (`5fd1781`) | SafeERC20, transient reentrancy guard, EIP-712, ECDSA, math, and proxy test fixture |
| `vault-v2` | tag 2026-07-08 (`549b113`) | Morpho VaultV2 interfaces in the adapter compile graph |
| `account-abstraction` | v0.7.0 (`7af70c8`) | Canonical EntryPoint v0.7 interfaces and implementation used by Modular Account v2.0.1 |
| `modular-account-v2` | v2.0.1 (`efab648`) | Exact Alchemy `ModularAccount` source used by the end-to-end compatibility suite |
| `reference-implementation-v080` | `c9b256c` | ERC-6900 v0.8.0 package commit recorded in Modular Account v2.0.1's lockfile; production interfaces/base module and Alchemy compile dependency |
| `solady-v00237` | v0.0.237 (`24b6272`) | Exact Solady release recorded in Modular Account v2.0.1's lockfile |
| `reference-implementation` | v0.8.1 (`65892c2`) | Legacy top-level test utility providing `EntryPointUtils`; not the ERC-6900 interface remapping used by production code |
| `halmos-cheatcodes` | `6da4e69` | Halmos-oriented properties; upstream has no release tag at this pin |

## Version boundaries

Alchemy Modular Account v2.0.1 targets EntryPoint v0.7 at
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`. EntryPoint v0.8 changes important
UserOperation and hash semantics; upgrading `account-abstraction` is an account-wide
migration, not a routine dependency bump.

The production Grow contracts deliberately compile against ERC-6900 reference
implementation v0.8.0 because that is the exact interface/base-module dependency of
the pinned Alchemy release. The separate v0.8.1 checkout is used only for a deployment
helper in the local EntryPoint fixture. Do not change the global ERC-6900 remapping to
v0.8.1 without revalidating interface IDs, account compilation, and module behavior.

The Alchemy source and its two exact transitive pins are top-level submodules here so
the compatibility test does not depend on mutable package-manager resolution. The
test validates source-level integration using this repository's Solidity 0.8.36/Cancun
profile; production deployment must still verify the exact deployed account bytecode,
proxy implementation, EntryPoint, and chain configuration.

## Update procedure

Treat any account, EntryPoint, ERC-6900, OpenZeppelin, venue-interface, or compiler
change as security-sensitive:

1. Review upstream diffs and release notes.
2. Update the gitlink and the exact pin in this file and `.gitmodules`.
3. Run `forge fmt --check`, `forge build --sizes`, `forge test`, and `forge lint`.
4. Re-run the exact Alchemy end-to-end lifecycle, invariant suite, and relevant fork
   tests.
5. Re-simulate production-shaped signed UserOperations through the target bundler.
