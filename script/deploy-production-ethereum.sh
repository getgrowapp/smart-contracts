#!/usr/bin/env bash
# Deploy GrowYield production stack on Ethereum (1) — Aave USDC + Morpho gbyGBP/ghyGBP.
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

ENV="${1:-production-ethereum}"
CONFIG="script/config/${ENV}.json"
if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG" >&2
  exit 1
fi

DEPLOYER_ADDR="$(deployer_address)"
echo "Broadcasting GrowYield Ethereum deploy ($ENV) ..."
echo "Deployer: $DEPLOYER_ADDR"
echo "RPC: ${ETH_RPC_URL%%/*}://… (redacted)"

BROADCAST_ARGS="$(forge_broadcast_args)"
VERIFY_ARGS=()
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  VERIFY_ARGS=(--verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY")
fi

# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/Deploy.s.sol \
  --sig "run(string)" "$ENV" \
  --rpc-url "$ETH_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  "${VERIFY_ARGS[@]}" \
  -vvv

echo "Deployment artifact:"
cat "deployments/${ENV}.json"
