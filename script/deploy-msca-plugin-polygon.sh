#!/usr/bin/env bash
# Deploy GrowYield MSCA plugin on Polygon (137). Executor/registry unchanged.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"

export POLYGON_RPC_URL="${POLYGON_RPC_URL:-https://polygon-bor-rpc.publicnode.com}"
require_deployer

echo "Deployer: $(deployer_address)"
echo "Executor: $(node -e "console.log(require('./deployments/production-polygon-msca.json').executor)")"
echo "RPC: $POLYGON_RPC_URL"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production-polygon \
  --rpc-url "$POLYGON_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-polygon-msca.json').mscaPlugin)")
echo ""
echo "After deploy:"
echo "  cd ../grow-backend"
echo "  npx ts-node scripts/generate-polygon-grow-yield-msca-plugin-migration.ts --apply"
echo ""
echo "  New plugin: $NEW_PLUGIN"
