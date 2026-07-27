# Deployments

Deployment artifacts written by `script/Deploy.s.sol`, one JSON file per environment
(`<env>.json`, matching `script/config/<env>.json`).

**Commit these files.** After every broadcast, the run writes/overwrites
`deployments/<env>.json` with the on-chain addresses, chain id, timestamp, and source
commit. Push the updated artifact to the repository so deployed addresses are tracked in
version control and reviewable in the deploy PR — the repo is the source of truth for what
is live on each network.

Stamp the source commit into the artifact by exporting it before broadcasting:

```sh
GIT_COMMIT=$(git rev-parse HEAD) \
forge script script/Deploy.s.sol --sig "run(string)" staging \
  --rpc-url "$BASE_RPC_URL" --broadcast --private-key "$PK"
```

Each file contains:

| Field | Meaning |
|---|---|
| `chainId` | Chain the stack was deployed to |
| `timestamp` | Block timestamp of the deploy |
| `commitSha` | `GIT_COMMIT` at deploy time (empty if unset) |
| `deployer` | `GrowYieldDeployer` (CREATE2) address |
| `executor` | `GrowYieldExecutor` address |
| `policyModule` | `GrowYieldPolicyModule` address |
| `registry` | `GrowYieldAdapterRegistry` address (wired into the executor) |
| `registryPendingOwner` | Governance address offered registry ownership; it must call `acceptOwnership()` |
| `adapterAddresses` / `adapterKinds` | Parallel arrays: one adapter per supported protocol |
| `vaultAddresses` / `vaultKinds` / `vaultAdapters` / `vaultCanDeposit` / `vaultCanRedeem` | Parallel arrays: the venue set admitted at deploy time, and the protocol adapter each routes through |

Only a real broadcast writes the artifact; a simulation logs the plan and leaves the file
alone, so a dry run cannot overwrite the record of what is live.
