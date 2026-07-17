# GrowYield security notes

> Historical note: the EIP-1271 `PolicySigner` beta described by the former version
> of this file has been removed. It is not compatible with the current contracts.

The current design is a direct ERC-6900 UserOperation validation module for Alchemy
Modular Account v2.0.1. Its primary security properties are:

- Account-scoped policy owners revocable through the smart account's owner path.
- Account-selected, nonzero validation entities with nonce-based module routing.
- A pinned sponsor and immutable UserOperation gas/fee ceilings.
- Canonical approve/execute/revoke batches only.
- Explicit exact, full-balance, and previous-output amount semantics.
- A signed absolute output floor plus a deployment loss-capped adapter preview.
- Finite account-owned deposit/redeem epoch limits that cannot be silently reset.
- A constructor-fixed, code-hash-pinned adapter registry.
- A one-way deployment guardian that can stop deposits but never redemptions.

The authoritative current documents are:

- [`../SECURITY_REVIEW.md`](../SECURITY_REVIEW.md) — controls, trust boundaries,
  residual risks, production checklist, and verification coverage.
- [`VALIDATION-MODULE-ARCHITECTURE.md`](VALIDATION-MODULE-ARCHITECTURE.md) — contract
  catalogue, diagrams, Alchemy v2.0.1 entity routing, owner onboarding, and complete
  automated rebalance flow.

Historical beta addresses and behavior remain only in
[`BETA-FREEZE-REPORT.md`](BETA-FREEZE-REPORT.md) for incident and migration context.
They must not be used as deployment guidance for this repository.
