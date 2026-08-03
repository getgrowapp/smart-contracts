#!/usr/bin/env bash
# Deploy GrowYield MSCA plugin (grow.yield-policy.7.0.0). Executor/registry unchanged.
# Latest bytecode includes _requireApprovedExecutor on ephemeral allowance path.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"
echo "Deployer: $(deployer_address)"
echo "Policy module: $(node -e "console.log(require('./deployments/production-msca.json').policyModule)")"

# shellcheck disable=SC2046
forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  $(forge_broadcast_args) \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-msca.json').mscaPlugin)")
echo ""
echo "After deploy:"
echo "  cd ../grow-backend"
echo "  npx ts-node scripts/generate-base-grow-yield-msca-plugin-migration.ts --apply"
echo "  (or omit --apply to write SQL only, then run migration + npm run generate:constants)"
echo ""
echo "  Railway production env (when ready to surface install to users):"
echo "    GROW_YIELD_MODULE_ENABLED=true"
echo ""
echo "  New plugin: $NEW_PLUGIN"
