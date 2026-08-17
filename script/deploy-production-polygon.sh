#!/usr/bin/env bash
# Deploy GrowYield production stack on Polygon (137) — Morpho-only (gbyJPY / ghyJPY).
# Prerequisite: ./script/deploy-morpho-eligibility-polygon.sh
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
  process.stdout.write((cfg.morphoEligibilityChildren || [])[0] || '');
")"

if [ -z "$CHILD" ]; then
  echo "Config missing morphoEligibilityChildren" >&2
  exit 1
fi

IS_ELIGIBLE="$(cast call "$ELIGIBILITY" "isEligibleVault(address)(bool)" "$CHILD" --rpc-url "$POLYGON_RPC_URL" 2>/dev/null || echo false)"
if [ "$IS_ELIGIBLE" != "true" ]; then
  echo "Morpho child $CHILD is not eligible on $ELIGIBILITY." >&2
  echo "Run: ./script/deploy-morpho-eligibility-polygon.sh $ENV" >&2
  exit 1
fi

DEPLOYER_ADDR="$(deployer_address)"
echo "Broadcasting GrowYield Polygon deploy ($ENV) ..."
echo "Deployer: $DEPLOYER_ADDR"
echo "Morpho eligibility: $ELIGIBILITY"

BROADCAST_ARGS="$(forge_broadcast_args)"
# shellcheck disable=SC2086
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}" \
forge script script/Deploy.s.sol \
  --sig "run(string)" "$ENV" \
  --rpc-url "$POLYGON_RPC_URL" \
  $BROADCAST_ARGS \
  --broadcast \
  --slow \
  -vvv

echo "Deployment artifact:"
cat "deployments/${ENV}.json"
