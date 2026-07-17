# GrowYield security

The former EIP-1271 `PolicySigner` architecture has been removed. Its configuration,
signature framing, and expiry behavior do not apply to the current contracts.

Current security documentation:

- [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) — controls, authority, residual risks,
  production checklist, and verification coverage.
- [`docs/VALIDATION-MODULE-ARCHITECTURE.md`](docs/VALIDATION-MODULE-ARCHITECTURE.md) —
  ERC-6900 module architecture, Alchemy nonce routing, onboarding, and execution flow.
- [`docs/SECURITY-yield-1271.md`](docs/SECURITY-yield-1271.md) — concise security index.

Historical beta deployment information is retained only in
[`docs/BETA-FREEZE-REPORT.md`](docs/BETA-FREEZE-REPORT.md) and must not be used as
current deployment guidance.
