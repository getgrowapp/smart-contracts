#!/usr/bin/env bash
# Deploy GrowYield production stack on Arbitrum (42161) — Aave USDT0 only.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"

export ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"
require_deployer

ENV="${1:-production-arbitrum}"
CONFIG="script/config/${ENV}.json"
if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG" >&2
  exit 1
fi

DEPLOYER_ADDR="$(deployer_address)"
echo "Broadcasting GrowYield Arbitrum deploy ($ENV) ..."
echo "Deployer: $DEPLOYER_ADDR"
echo "RPC: $ARBITRUM_RPC_URL"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/Deploy.s.sol \
  --sig "run(string)" "$ENV" \
  --rpc-url "$ARBITRUM_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

echo "Deployment artifact:"
cat "deployments/${ENV}.json"
