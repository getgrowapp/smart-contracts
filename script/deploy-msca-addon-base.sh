#!/usr/bin/env bash
# Deploy GrowYield policy module v2 + MSCA plugin on Base. Executor/registry unchanged.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"
require_foundry_account

echo "Deployer: $(deployer_address)"
echo "Existing executor: $(node -e "console.log(require('./deployments/production.json').executor)")"

forge script script/DeployMscaAddon.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

cat deployments/production-msca.json
