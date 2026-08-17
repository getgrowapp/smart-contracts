#!/usr/bin/env bash
# Deploy MorphoVaultEligibility on Polygon (137) and allowlist JPYC Morpho child vaults.
# Run before deploy-production-polygon.sh (registry admission requires eligible children).
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"

export POLYGON_RPC_URL="${POLYGON_RPC_URL:-https://polygon-rpc.com}"
require_deployer

ENV="${1:-production-polygon}"
CONFIG="script/config/${ENV}.json"
if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG" >&2
  exit 1
fi

ELIGIBILITY="$(node -e "
  const fs = require('fs');
  const cfg = JSON.parse(fs.readFileSync('$CONFIG', 'utf8'));
  process.stdout.write(cfg.registry.registrars.morphoEligibility);
")"

CHILD="$(node -e "
  const fs = require('fs');
  const cfg = JSON.parse(fs.readFileSync('$CONFIG', 'utf8'));
  const children = cfg.morphoEligibilityChildren || [];
  if (!children.length) process.exit(1);
  process.stdout.write(children[0]);
")"

echo "Morpho eligibility oracle (predicted): $ELIGIBILITY"
echo "JPYC child vault: $CHILD"
echo "RPC: $POLYGON_RPC_URL"

if cast code "$ELIGIBILITY" --rpc-url "$POLYGON_RPC_URL" | grep -qv "^0x$"; then
  IS_ELIGIBLE="$(cast call "$ELIGIBILITY" "isEligibleVault(address)(bool)" "$CHILD" --rpc-url "$POLYGON_RPC_URL")"
  if [ "$IS_ELIGIBLE" = "true" ]; then
    echo "Eligibility oracle already deployed and child is eligible."
    exit 0
  fi
  echo "Oracle deployed; broadcasting setEligible for child..."
else
  echo "Broadcasting eligibility oracle deploy + setEligible..."
fi

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/DeployMorphoVaultEligibility.s.sol \
  --sig "run(string)" "$ENV" \
  --rpc-url "$POLYGON_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

echo "Eligibility artifact:"
cat "deployments/morpho-eligibility-${ENV}.json"
