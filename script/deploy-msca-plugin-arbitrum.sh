#!/usr/bin/env bash
# Deploy GrowYield MSCA plugin on Arbitrum (42161). Executor/registry unchanged.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"

export ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"
require_deployer

STACK="deployments/production-arbitrum.json"
MSCA="deployments/production-arbitrum-msca.json"
if [ ! -f "$MSCA" ]; then
  node -e "
    const fs = require('fs');
    const stack = JSON.parse(fs.readFileSync('$STACK', 'utf8'));
    fs.writeFileSync('$MSCA', JSON.stringify({
      chainId: stack.chainId,
      commitSha: stack.commitSha || '',
      executor: stack.executor,
      mscaPlugin: stack.policyModule,
      policyModule: stack.policyModule,
      timestamp: stack.timestamp || 0,
    }, null, 2) + '\n');
  "
fi

echo "Deployer: $(deployer_address)"
echo "Executor: $(node -e "console.log(require('./deployments/production-arbitrum-msca.json').executor)")"
echo "RPC: $ARBITRUM_RPC_URL"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production-arbitrum \
  --rpc-url "$ARBITRUM_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-arbitrum-msca.json').mscaPlugin)")
echo ""
echo "After deploy:"
echo "  cd ../grow-backend"
echo "  npx ts-node scripts/generate-arbitrum-grow-yield-msca-plugin-migration.ts --apply"
echo ""
echo "  New plugin: $NEW_PLUGIN"
