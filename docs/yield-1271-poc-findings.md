# GrowYield EIP-1271 PoC — results vs V6

**Status: live Base round-trip succeeded.** Architecture kept (no custom Grow validator/hook). Hash/sig fixes from earlier findings applied.

## Fixes applied (Alchemy MA v2.0.1)

1. `isValidSignature` compares against `userOpHash.toEthSignedMessageHash()` (not raw UserOp hash).
2. Outer UserOp.signature = `0xFF || 0x01 (CONTRACT_OWNER) || abi.encode(Proof)`.
3. Alchemy MA nonce key = `(entityId << 8) | options` (SDK/`buildFullNonceKey`), not bare `entityId`.

## Deployed (Base 8453) — reuse V6 registry

| Contract | Address |
|---|---|
| GrowYieldExecutor1271V2 | `0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE` |
| GrowYield1271PolicySignerV3 | `0x7fde78b9AF63640cAAEEeb15343319612B1a9d8E` |
| Registry (existing V6) | `0x7F219F5009Df002307Cf759994a1370De3d089E0` |

## Onboarding (one owner UserOp)

| Field | Value |
|---|---|
| Smart account | `0x68f1ac3B164519EA9cb66418216D548C39283021` |
| EntityId | 2 (SingleSigner → policy signer; V6 remains entity 1) |
| Automation | `0x5F6694c633DfB3f8Dc46791CF34A70643515422D` |
| UserOp | `0xb1e44f08c8ed68858a24818313f280c167dcdde5e9a02101413585dfb6f42f41` |
| Tx | `0x4e93427b7c116e118b869d03b2bb1ddef1fbdfb4390e60e7c89fb9c20140e7a3` |
| gasUsed | 242,171 |

Installed Alchemy `SingleSignerValidationModule` only — **no** Grow validator or policy hook.

## Live ops (automation-signed only)

| Op | UserOp | Tx | gasUsed |
|---|---|---|---|
| depositAll → Aave | `0x8a9cf3e034e116cb9950d0bbe3210f6bbe0b122a50ce3822f75148b5252d7f2d` | `0x61c47530003f83a8ba7cf246c679e9fa61f3f660f6b0a14c60342d8712ae0b99` | 681,888 |
| reallocateAll Aave → Morpho | `0xbfa01eb016192171e3225bc9cca903cd551a41c00f1fd88f5e68b2e16e87350e` | `0xc7a303a49c69f369d4a90b917cf4bf2c6dcaa8e9b0342e37a5178c5a98a86241` | 1,270,001 |
| withdrawAll Morpho | `0x2e618d4eae3fa2e5ab5038225f3006d5166622335b9e84cb05af5e6d473fd5f3` | `0xcd03e413cc76073c873dcf10025238a7bb26ca5e1a439146cca32053afccc779` | 905,876 |

Round-trip ≈ 1 USDC → `999996` USDC on SCW. Positions cleared; executor USDC allowance `0`.

## Comparison vs V6

| Metric | EIP-1271 | V6 |
|---|---|---|
| End-to-end works | **Yes** | Yes |
| Onboarding UserOps | **1** (configure + install SingleSigner) | **1** (install Grow validator + hook) |
| Custom Grow modules on account | **None** (stock Alchemy SingleSigner) | Validator + PolicyHook |
| Deployed bytecode (new) | Signer 5,193 + Executor 4,620 = **9,813** | Val 2,092 + Hook 4,358 + Exec 3,720 = **10,170** |
| Core Solidity LOC (approx) | **444** (1271 dir) | **804** (validator+hook+executor+batch+install) |
| Install gas | 242k | (prior PoC install) |
| Deposit / realloc / withdraw gas | 682k / 1.27M / 906k | **494k / 1.16M / 696k** |
| Bundler | Works; needs ≥~500k `verificationGasLimit` (dummy INVALID underestimates) | Works; Grow packing + often `executeUserOp` wrap |
| Trust | Alchemy SingleSigner + Grow 1271 policy in `isValidSignature` | Grow validateUserOp + execution hook |
| Simpler? | **Simpler on-account surface** (stock SingleSigner only). Offchain is heavier (embedded UserOp Proof; VGL bump + paymaster refresh). | Heavier on-chain modules; lighter Grow-packed 71-byte sigs |

V6 live ops are cheaper on gas for this same round-trip. EIP-1271 wins on account simplicity (no custom 6900 modules).

### V6 live gas (same account / prior PoC)

| Op | Tx | gasUsed |
|---|---|---|
| deposit | `0x760b06c07b302f9e1a7d3f56d524d1cd3234a5efe8b415c0127c059622846d74` | 494,271 |
| realloc | `0x0468d110728ab0063fa9d050225243538ab7d40623b83d7792b8bf29b350179d` | 1,161,078 |
| withdraw | `0x6c998433bd624a30eae7dc7bcc056ab1f06166e52bef31c326707641cd7be8e7` | 696,326 |

## Operational notes

- Dummy gas estimation must use a **structurally valid** Proof that returns `INVALID` (hash mismatch) — zero bytes revert on `abi.decode` → AA23.
- Real validation burns far more gas than the invalid-dummy estimate; PoC pins `verificationGasLimit ≥ 500_000` then refreshes Alchemy paymaster.
- Do **not** use Account Kit `packUOSignature` for this path (`0xFF\|\|0x00\|\|…` is EOA-only).

## Success criteria

| Criterion | Met |
|---|---|
| One owner onboarding UserOp | Yes |
| Later ops automation-only | Yes |
| No custom Grow validator/hook | Yes |
| EIP-1271 binds exact UserOp | Yes (embedded unsigned UO + eth-signed hash) |
| Base deposit/realloc/withdraw | Yes |
| No persistent vault approvals | Yes |
| Funds owned by SCW | Yes |

V6 remains intact. Product choice: 1271 is simpler account surface; V6 has lighter/cheaper offchain signing and less fragile gas estimation.
