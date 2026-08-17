#!/usr/bin/env bash
# Deploy GrowYield MSCA plugin on Ethereum (1). Executor/registry unchanged.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"

if [ -z "${ETH_RPC_URL:-}" ] && [ -f ../grow-backend/.env ]; then
  ALCHEMY_API_KEY="$(load_env_private_key ALCHEMY_API_KEY ../grow-backend/.env || true)"
  if [ -n "${ALCHEMY_API_KEY:-}" ]; then
    ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
  fi
fi
export ETH_RPC_URL="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
require_deployer

STACK="deployments/production-ethereum.json"
MSCA="deployments/production-ethereum-msca.json"
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
echo "Executor: $(node -e "console.log(require('./deployments/production-ethereum-msca.json').executor)")"
echo "RPC: ${ETH_RPC_URL%%/*}://… (redacted)"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production-ethereum \
  --rpc-url "$ETH_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-ethereum-msca.json').mscaPlugin)")
echo ""
echo "After deploy:"
echo "  cd ../grow-backend"
echo "  npx ts-node scripts/generate-ethereum-grow-yield-msca-plugin-migration.ts --apply"
echo ""
echo "  New plugin: $NEW_PLUGIN"
