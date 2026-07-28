#!/usr/bin/env bash
# Deploy GrowYield policy module v2 + MSCA plugin on Base. Executor/registry unchanged.
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

if [ -z "${PRIVATE_KEY}" ]; then
  echo "Set RELAYER_FACTORY_DEPLOY_PRIVATE_KEY in grow-backend/.env" >&2
  exit 1
fi

echo "Deployer: $(cast wallet address --private-key "$PRIVATE_KEY")"
echo "Existing executor: $(node -e "console.log(require('./deployments/production.json').executor)")"

forge script script/DeployMscaAddon.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

cat deployments/production-msca.json
