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
MORPHO_ELIGIBILITY="0x006A9c616E87F10635896D3B16D1E6922B5Ace16"
IS_ELIGIBLE=$(cast call "$MORPHO_ELIGIBILITY" "isEligibleVault(address)(bool)" "$GBY_CHILD" --rpc-url "$BASE_RPC_URL")
if [ "$IS_ELIGIBLE" = "false" ]; then
  echo "Setting Morpho eligibility for gbyUSD child $GBY_CHILD ..."
  cast send "$MORPHO_ELIGIBILITY" "setEligible(address,bool)" "$GBY_CHILD" true \
    --rpc-url "$BASE_RPC_URL" --private-key "$PRIVATE_KEY"
fi

# Euler gbyUSD wrapper child (Clearstar Earn USDC) must be allowlisted before adapter deploy.
EULER_CHILD="0x8bF41Ad2b816F7c220b22F4BCD63fC2A35Ab4247"
GROW_SAFE="0xe8D212F886109cbf01e8294E3640a6Fb05544ff3"
EULER_ELIGIBILITY="${EULER_STRATEGY_ELIGIBILITY:-}"

if [ -z "$EULER_ELIGIBILITY" ] || [ "$EULER_ELIGIBILITY" = "0x0000000000000000000000000000000000000000" ]; then
  EULER_ELIGIBILITY=$(node -e "const j=require('./script/config/production.json'); process.stdout.write(j.adapters.eulerEarn?.[0]?.eligibility || '')")
fi

if [ -z "$EULER_ELIGIBILITY" ] || [ "$EULER_ELIGIBILITY" = "0x0000000000000000000000000000000000000000" ]; then
  echo "Deploying EulerStrategyEligibility owned by Grow Safe ..."
  EULER_ELIGIBILITY=$(forge create src/oracles/EulerStrategyEligibility.sol:EulerStrategyEligibility \
    --constructor-args "$GROW_SAFE" \
    --rpc-url "$BASE_RPC_URL" --private-key "$PRIVATE_KEY" --json | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).deployedTo))")
  node -e "
    const fs = require('fs');
    const path = 'script/config/production.json';
    const j = JSON.parse(fs.readFileSync(path, 'utf8'));
    j.adapters.eulerEarn[0].eligibility = '$EULER_ELIGIBILITY';
    fs.writeFileSync(path, JSON.stringify(j, null, 2) + '\n');
  "
  echo "EulerStrategyEligibility: $EULER_ELIGIBILITY"
fi

EULER_IS_ELIGIBLE=$(cast call "$EULER_ELIGIBILITY" "isEligibleStrategy(address)(bool)" "$EULER_CHILD" --rpc-url "$BASE_RPC_URL")
if [ "$EULER_IS_ELIGIBLE" = "false" ]; then
  echo "Setting Euler strategy eligibility for $EULER_CHILD ..."
  cast send "$EULER_ELIGIBILITY" "setEligible(address,bool)" "$EULER_CHILD" true \
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
