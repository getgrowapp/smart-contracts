#!/usr/bin/env bash
# Deploy fixed GrowYield MSCA plugin (EP v0.6 paymaster parsing). Policy module + executor unchanged.
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
export BASE_RPC_URL="$(read_env RPC_URL_BASE)"
export BASESCAN_API_KEY="$(read_env BASESCAN_API_KEY)"
export ETHERSCAN_API_KEY="$(read_env ETHERSCAN_API_KEY)"
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export GIT_COMMIT="$(git rev-parse HEAD)"

if [ -z "${PRIVATE_KEY}" ]; then
  echo "Set RELAYER_FACTORY_DEPLOY_PRIVATE_KEY in grow-backend/.env" >&2
  exit 1
fi

echo "Deployer: $(cast wallet address --private-key "$PRIVATE_KEY")"
echo "Policy module: $(node -e "console.log(require('./deployments/production-msca.json').policyModule)")"

forge script script/DeployMscaPlugin.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}" \
  -vvv

NEW_PLUGIN=$(node -e "console.log(require('./deployments/production-msca.json').mscaPlugin)")
echo ""
echo "Update grow-backend:"
echo "  1. Set grow_yield_msca_plugin_address = $NEW_PLUGIN (DB + constants)"
echo "  2. npm run generate:constants (grow-backend)"
echo "  3. Re-run smoke — it will uninstall the old plugin and reinstall $NEW_PLUGIN"
