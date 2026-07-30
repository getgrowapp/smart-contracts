#!/usr/bin/env bash
# Deploy GrowYield production stack on Base (8453) via Deploy.s.sol.
# Signer: encrypted Foundry keystore (FOUNDRY_ACCOUNT, default grow-deployer).
# Requires BASE_RPC_URL and BASESCAN_API_KEY (or ETHERSCAN_API_KEY) for --verify.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/forge-env.sh"
require_foundry_account

# gbyUSD child vault must be allowlisted on the Morpho eligibility oracle before adapter deploy.
GBY_CHILD="0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100"
ELIGIBILITY="0x006A9c616E87F10635896D3B16D1E6922B5Ace16"
IS_ELIGIBLE=$(cast call "$ELIGIBILITY" "isEligibleVault(address)(bool)" "$GBY_CHILD" --rpc-url "$BASE_RPC_URL")
if [ "$IS_ELIGIBLE" = "false" ]; then
  echo "Setting Morpho eligibility for gbyUSD child $GBY_CHILD ..."
  cast send "$ELIGIBILITY" "setEligible(address,bool)" "$GBY_CHILD" true \
    --rpc-url "$BASE_RPC_URL" \
    --account "$FOUNDRY_ACCOUNT"
fi

DEPLOYER_ADDR="$(deployer_address)"
echo "Broadcasting GrowYield production deploy ..."
echo "Signer account: $FOUNDRY_ACCOUNT ($DEPLOYER_ADDR)"
forge script script/Deploy.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

echo "Deployment artifact:"
cat deployments/production.json
