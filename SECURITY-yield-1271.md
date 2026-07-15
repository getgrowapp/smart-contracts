# GrowYield EIP-1271 Security Notes (Beta)

Frozen scope: `src/yield-1271/` (PolicySigner V3 + Executor V2 + libs) used with Alchemy Modular Account V2 `SingleSignerValidationModule` and an owner-controlled venue registry.

## Architecture

1. Smart account installs Alchemy `SingleSignerValidationModule` with the Grow **PolicySigner** as the configured contract signer (`SignatureType.CONTRACT_OWNER`).
2. Automation submits ERC-4337 UserOps. Outer signature is `0xFF || 0x01 || abi.encode(Proof)`.
3. Module calls `PolicySigner.isValidSignature(ethSignedUserOpHash, proof)`.
4. Proof embeds the **unsigned** UserOp, EntryPoint, expiry, and an EIP-712 automation signature over `(userOpHash, validUntil)`.
5. Policy allows only `executeBatch` of exactly: `approve(executor,max)` → `executor.{depositAll|withdrawAll|reallocateAll}` → `approve(executor,0)`.
6. Executor moves **full balances** of the calling account into/out of registry-approved Morpho/Aave venues. Recipient is always `msg.sender` (the smart account) except transient intermediate balances on the executor during `reallocateAll`.

## Trusted components

| Component | Trust assumption |
|---|---|
| Alchemy MA v2 + SingleSignerValidationModule | Correct EIP-1271 call with `userOpHash.toEthSignedMessageHash()`; nonce key semantics |
| Canonical EntryPoint `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Enforces nonce / UserOp uniqueness |
| Registry owner | Correct venue metadata (`asset`, `positionToken`, enter/exit flags) |
| PolicySigner + Executor bytecode | As deployed; no upgrade proxy in this design |
| Automation EOA/key | Compromised key ⇒ can move **full** balances through allowed venues only |

## Registry-owner powers

- Enable/disable **entry** and **exit** per venue independently.
- Point `asset` / `positionToken` at venue tokens (misconfiguration can brick or misroute ops).
- Owner cannot directly withdraw user funds without going through the account’s installed validation path.

## Automation-key blast radius

If the configured automation signer is compromised:

- Attacker can authorize any policy-compliant batch until `config.validUntil` / proof `validUntil` / owner removes configuration / uninstalls module.
- Attacker **cannot**: set arbitrary recipients, amounts (full-balance only), native value, unsupported selectors, or call non-executor targets via this policy.
- Attacker **can**: deposit/withdraw/reallocate across **currently enter/exit-enabled** venues for the same underlying (subject to registry).

Mitigations: rotate automation key (`configure`), set short `validUntil`, uninstall SingleSigner entity, disable venue **entry** (preserve exits).

## Supported operations

- `depositAll(protocol, target, asset)`
- `withdrawAll(protocol, target, assetHint)`
- `reallocateAll(src…, dst…)` only when `source.asset == destination.asset`

## Invariants (enforced in tests)

- After successful executor ops: executor holds no underlying or position tokens.
- Withdrawn assets and destination shares credit the smart account (`msg.sender`).
- Reallocation reverts on underlying mismatch.
- Policy rejects arbitrary recipient/amount/value/target/selector patterns; executor ABIs omit recipient/amount fields.
- Successful batches include approve-zero; allowance SCW→executor is zero afterward (policy + handler practice).
- Invalid / malformed proofs return `0xffffffff` (never EIP-1271 magic); decode failures are caught.

## Known limitations

- Gas estimation must use a **structurally valid** Proof that returns `INVALID` (e.g. hash mismatch). Empty/junk proofs no longer revert, but estimates still understate real validation gas — pin high `verificationGasLimit` and refresh paymaster.
- Approve token is bound to the operation source token via registry lookup (deposit underlying / withdraw & realloc source position token). Unknown venues revert in policy resolution and map to EIP-1271 invalid.
- Morpho/Aave venue correctness depends on registry owner diligence and protocol behavior (`maxLossBps` slippage guard).
- No on-chain automation volume limits or per-tx caps (full balance).
- Chain ID / EntryPoint binding is via embedded UserOp hash; wrong chain proof is invalid on that chain.

## Emergency: disable new entry, preserve exits

1. Registry owner sets venue `canEnter = false`, leave `canExit = true` (and keep exit metadata intact).
2. New deposits / reallocations **into** that venue fail at `entryVenue`.
3. Users (and automation) can still `withdrawAll` / reallocate **out** via `exitVenue`.
4. Optionally: `PolicySigner.removeConfiguration()` or uninstall the SingleSigner entity to stop automation entirely while owner retains account control.
