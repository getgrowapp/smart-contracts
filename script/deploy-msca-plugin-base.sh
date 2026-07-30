#!/usr/bin/env bash
# Deploy fixed GrowYield MSCA plugin (EP v0.6 paymaster parsing). Policy module + executor unchanged.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"
require_foundry_account

echo "Deployer: $(deployer_address)"
echo "Policy module: $(node -e "console.log(require('./deployments/production-msca.json').policyModule)")"

forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-msca.json').mscaPlugin)")
echo ""
echo "After deploy:"
echo "  1. Update grow_yield_module_address AND grow_yield_msca_plugin_address = $NEW_PLUGIN"
echo "  2. Regenerate backend constants and run DB migrations as needed"
