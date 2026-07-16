# GrowYield EIP-1271 Security Notes (Adapter architecture, V3/V4)

Scope: `src/yield-1271/` (PolicySigner V4 + Executor V3 + adapters + libs) used with
Alchemy Modular Account v2 `SingleSignerValidationModule` and an owner-governed
adapter allowlist.

## Architecture

1. Smart account installs Alchemy `SingleSignerValidationModule` with the Grow
   **PolicySigner** as the configured contract signer (`SignatureType.CONTRACT_OWNER`).
2. Automation submits ERC-4337 UserOps. Outer signature is `0xFF || 0x01 || abi.encode(Proof)`.
3. Module calls `PolicySigner.isValidSignature(ethSignedUserOpHash, proof)`. The
   signer **pins the module address**: any other caller gets `0xffffffff`. This turns
   Alchemy's version-specific hash wrapping (`toEthSignedMessageHash` in v2.0.1) into
   an explicit on-chain compatibility declaration — a module upgrade fails closed
   instead of silently validating the wrong scheme. Off-chain pre-flight `eth_call`s
   must set `from = validationModule`.
4. Proof embeds the **unsigned** UserOp, EntryPoint, expiry, and an EIP-712 automation
   signature over `(userOpHash, validUntil)`. UserOp hashing is the EntryPoint v0.7
   scheme (see `DEPENDENCIES.md` for the deliberate account-abstraction pin).
5. Policy allows only the canonical `executeBatch`:
   `[approve(token_1,max) … approve(token_k,max), executor.execute(ops), approve(token_1,0) … approve(token_k,0)]`
   where `token_1..k` are exactly the unique source tokens of `ops` in first-appearance
   order (deposit → `adapter.asset()`, redeem → `adapter.positionToken()`), every
   spender is the executor, and every adapter is registry-approved for its direction
   (checked before any staticcall into adapter code). `ops` is capped at 4 and must be
   canonically ABI-encoded (exact length).
6. Executor runs each `Operation {adapter, kind, amount}` with funds moving
   account → adapter → venue → account. `amount` is granular;
   `type(uint256).max` = full balance.

## Division of enforcement

| Layer | Enforces | Cannot enforce |
|---|---|---|
| PolicySigner (validation-time) | calldata shape, targets, approval bracketing, source-token binding, adapter allowlist, automation signature + expiry | anything about execution outcome |
| Executor (execution-time) | receiver = `msg.sender` (no recipient in ABI), exact-amount receipt (fee-on-transfer fails closed), loss cap `maxLossBps` vs adapter preview, no residual on executor/adapters, reentrancy (transient guard), allowlist re-check | which key authorized the op |
| Adapters | venue config validation at construction; deposit-time drift re-checks (Aave reserve re-pointing, Morpho child eligibility + liquidity designation) — fail closed; exits never drift-gated — fail open | — |

The executor exists because ERC-4626 `deposit`/`redeem` and Aave `supply`/`withdraw`
have no min-output parameter: a post-call balance check in the execution path is the
only place a loss cap can live. Calling venues directly from the account would forfeit it.

## Trusted components

| Component | Trust assumption |
|---|---|
| Alchemy MA v2 + SingleSignerValidationModule (pinned) | Correct EIP-1271 call with `userOpHash.toEthSignedMessageHash()`; nonce semantics |
| Canonical EntryPoint v0.7 `0x00000000717…a032` | Enforces nonce / UserOp uniqueness |
| Registry owner (Safe/Timelock) | Only allowlists reviewed adapter contracts; adapters are venue-specific and immutable |
| Adapter bytecode | As deployed; adapters are `onlyExecutor` and hold funds only mid-call |
| PolicySigner + Executor bytecode | As deployed; no upgrade proxy in this design |
| Automation key | Compromise bounded by policy (below); per-account, revocable |

## Per-account configuration (why not one global automation key)

`config[account] = (signer, validUntil)` is each account's consent to a specific
automation key: per-account expiry, instant revocation (`removeConfiguration`) without
a module-uninstall UserOp, and per-account key rotation. A single global key would
give one compromise blast radius over every account. Installing the signer as session
key consents to the *policy*; `configure` consents to the *key*.

## Automation-key blast radius

If the configured automation key is compromised, the attacker can authorize
policy-compliant batches until expiry/revocation. They **cannot**: redirect funds (no
recipient anywhere in the ABI; outputs always credit the account), use native value,
call non-executor targets, leave standing allowances, or route through
non-allowlisted adapters. They **can**: move funds between currently-allowlisted
venues (including partial amounts) for the account's own benefit, subject to the loss
cap.

Mitigations: rotate key (`configure`), short `validUntil`, `removeConfiguration`,
uninstall the SingleSigner entity, or registry owner disables adapter deposits
(exits stay open).

## Invariants (enforced in tests)

- Executor and adapters never retain funds after a transaction (stateful invariant +
  Halmos residual property).
- All outputs credit `msg.sender`; the ABI has no recipient field.
- Caller's output delta ≥ `preview * (1 - maxLossBps)` and nonzero, per operation.
- Policy rejects non-canonical batches (wrong approvals/order/targets/selectors/value,
  extra or missing approval pairs, >4 ops, non-canonical encoding, unlisted adapters).
- Invalid/malformed proofs and non-module callers return `0xffffffff`, never revert.
- Successful batches end with zero allowance account→executor.

## Known limitations

- Gas estimation must use a structurally valid Proof that returns `INVALID`; estimates
  still understate real validation gas — pin a high `verificationGasLimit`.
- A module upgrade by Alchemy (changing the hash wrapping) stops automation silently
  on-chain (fails closed). Monitor the executor's `Executed` event cadence and alert
  on unexpected drop; redeploy the signer with the new module address to migrate.
- Venue solvency/oracle correctness is out of scope; `maxLossBps` bounds per-op
  slippage vs the venue's own preview, not venue insolvency.
- No on-chain automation volume limits or per-day caps.

## Emergency: disable new entry, preserve exits

1. Registry owner: `setAdapter(adapter, false, true)` — deposits blocked, exits open.
2. Morpho child turning ineligible or Aave reserve re-pointing blocks deposits
   automatically (adapter drift checks); exits remain open in both cases.
3. Per account: `removeConfiguration()` stops automation instantly; the account owner
   retains full manual control throughout.
