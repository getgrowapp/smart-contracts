#!/usr/bin/env bash
# Deploy MorphoVaultEligibility on Ethereum (1) and allowlist Steakhouse tGBP child.
# Run before redeploying the Ethereum GrowYield stack with Morpho.
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

echo "Deployer: $(deployer_address)"
echo "RPC: ${ETH_RPC_URL%%/*}://… (redacted)"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/DeployMorphoVaultEligibility.s.sol \
  --sig "run(string)" "$ENV" \
  --rpc-url "$ETH_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

echo "Eligibility artifact:"
cat "deployments/morpho-eligibility-${ENV}.json"
