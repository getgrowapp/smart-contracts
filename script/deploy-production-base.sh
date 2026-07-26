#!/usr/bin/env bash
# Deploy GrowYield production stack on Base (8453) via Deploy.s.sol.
# Uses the relay factory deployer EOA (RELAYER_FACTORY_DEPLOY_PRIVATE_KEY → 0xf5C7…).
# Also requires BASE_RPC_URL and BASESCAN_API_KEY (or ETHERSCAN_API_KEY) for --verify.
set -euo pipefail

cd "$(dirname "$0")/.."

read_env() {
  node -e "
    const fs = require('fs');
    const key = process.argv[1];
    const path = '../grow-backend/.env';
    if (!fs.existsSync(path)) process.exit(0);
    const text = fs.readFileSync(path, 'utf8');
    for (const line of text.split(/\n/)) {
      const m = line.match(new RegExp('^' + key + '=(.*)$'));
      if (!m) continue;
      let v = m[1].trim();
      if ((v.startsWith('\"') && v.endsWith('\"')) || (v.startsWith(\"'\") && v.endsWith(\"'\"))) {
        v = v.slice(1, -1);
      }
      process.stdout.write(v);
      break;
    }
  " "$1"
}

export PRIVATE_KEY="$(read_env RELAYER_FACTORY_DEPLOY_PRIVATE_KEY)"
export BASE_RPC_URL="$(read_env BASE_RPC_URL)"
export BASESCAN_API_KEY="$(read_env BASESCAN_API_KEY)"
export ETHERSCAN_API_KEY="$(read_env ETHERSCAN_API_KEY)"
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export GIT_COMMIT="$(git rev-parse HEAD)"

if [ -z "${ETHERSCAN_API_KEY}" ]; then
  export ETHERSCAN_API_KEY="${BASESCAN_API_KEY}"
fi
if [ -z "${BASESCAN_API_KEY}" ]; then
  export BASESCAN_API_KEY="${ETHERSCAN_API_KEY}"
fi

if [ -z "${PRIVATE_KEY}" ]; then
  echo "Set RELAYER_FACTORY_DEPLOY_PRIVATE_KEY in grow-backend/.env (relay deployer wallet)" >&2
  exit 1
fi

# gbyUSD child vault must be allowlisted on the Morpho eligibility oracle before adapter deploy.
GBY_CHILD="0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100"
ELIGIBILITY="0x006A9c616E87F10635896D3B16D1E6922B5Ace16"
IS_ELIGIBLE=$(cast call "$ELIGIBILITY" "isEligibleVault(address)(bool)" "$GBY_CHILD" --rpc-url "$BASE_RPC_URL")
if [ "$IS_ELIGIBLE" = "false" ]; then
  echo "Setting Morpho eligibility for gbyUSD child $GBY_CHILD ..."
  cast send "$ELIGIBILITY" "setEligible(address,bool)" "$GBY_CHILD" true \
    --rpc-url "$BASE_RPC_URL" --private-key "$PRIVATE_KEY"
fi

echo "Broadcasting GrowYield production deploy ..."
DEPLOYER_ADDR=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Relay deployer: $DEPLOYER_ADDR"
forge script script/Deploy.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

echo "Deployment artifact:"
cat deployments/production.json
