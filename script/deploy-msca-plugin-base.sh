#!/usr/bin/env bash
# Deploy GrowYield MSCA plugin (grow.yield-policy.7.0.0). Executor/registry unchanged.
# Latest bytecode includes _requireApprovedExecutor on ephemeral allowance path.
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
echo "  cd ../grow-backend"
echo "  npx ts-node scripts/generate-base-grow-yield-msca-plugin-migration.ts --apply"
echo "  (or omit --apply to write SQL only, then run migration + npm run generate:constants)"
echo ""
echo "  Railway production env (when ready to surface install to users):"
echo "    GROW_YIELD_MODULE_INSTALL_ENABLED=true"
echo "    GROW_YIELD_SKIP_SESSION_KEY_DEPLOY=true"
echo "    SESSION_KEY_ADDRESS=<policy owner>"
echo "    ALCHEMY_GAS_POLICY_ID=<gas manager policy>"
echo ""
echo "  New plugin: $NEW_PLUGIN"
