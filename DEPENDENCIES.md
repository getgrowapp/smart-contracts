# Dependency pins

Dependencies are **git submodules** under `lib/`, pinned by gitlink to the exact
commits below (annotated in `.gitmodules`). After cloning:

```bash
git submodule update --init   # top-level only; nested submodules not needed
```

Toolchain: solc pinned to **0.8.36** (latest stable at pin time), `evm_version = cancun`
(live on Base; enables the transient-storage reentrancy guard).

| lib | pin | rationale |
|---|---|---|
| forge-std | v1.16.2 | latest stable |
| openzeppelin-contracts | v5.6.1 | latest stable (SafeERC20, ReentrancyGuardTransient, EIP712, SignatureChecker, Ownable2Step) |
| vault-v2 (Morpho) | tag 2026-07-08 (`549b113`) | latest tagged release; interfaces only in compile graph |
| account-abstraction (eth-infinitism) | **v0.7.0 (`7af70c8`) — deliberate hold** | EntryPoint v0.8+ switched userOp hashing to an EIP-712 domain. Alchemy Modular Account v2 targets EntryPoint v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`), and `GrowUserOpHashLib` implements the v0.7 scheme. Upgrading this lib without a coordinated EntryPoint migration would silently desync proof hashes (fails closed, but bricks automation). Do not bump casually. |
| reference-implementation (ERC-6900) | v0.8.1 | latest stable; `Call` struct + `executeBatch` ABI unchanged from v0.8.0 (interface file renamed to `IERC6900Account.sol`) |
| halmos-cheatcodes (a16z) | commit `6da4e69` | no tagged releases upstream; pinned by commit |
