#!/usr/bin/env bash
# Admit remaining GrowYield venues on the MSCA production executor (Base 8453).
# Requires registry owner key (currently deployer until Safe accepts ownership).
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
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"

if [ -z "${PRIVATE_KEY}" ]; then
  echo "Set RELAYER_FACTORY_DEPLOY_PRIVATE_KEY in grow-backend/.env" >&2
  exit 1
fi

EXECUTOR="$(node -e "console.log(require('./script/config/add-vaults-production.json').executor)")"
DEPLOYER_ADDR=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER=$(cast call "$EXECUTOR" "owner()(address)" --rpc-url "$BASE_RPC_URL")
PENDING_OWNER=$(cast call "$EXECUTOR" "pendingOwner()(address)" --rpc-url "$BASE_RPC_URL")

echo "Executor:       $EXECUTOR"
echo "Signer:         $DEPLOYER_ADDR"
echo "Owner:          $OWNER"
echo "Pending owner:  $PENDING_OWNER"

if [ "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER_ADDR" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "Registry owner is not the relay deployer EOA." >&2
  echo "Use the Grow Safe:" >&2
  echo "  1. EXECUTOR=$EXECUTOR node grow-allocation-controller/script/safe/propose-accept-executor-ownership.mjs" >&2
  echo "  2. EXECUTOR=$EXECUTOR node grow-allocation-controller/script/safe/propose-add-executor-vaults.mjs --batch msca-remaining" >&2
  exit 1
fi

echo "Simulating addVaults ..."
forge script script/AddVaults.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  -vvv

if [ "${1:-}" != "--broadcast" ]; then
  echo ""
  echo "Dry run only. Re-run with --broadcast to submit on-chain:"
  echo "  ./script/add-vaults-production-base.sh --broadcast"
  exit 0
fi

echo "Broadcasting addVaults ..."
forge script script/AddVaults.s.sol \
  --sig "run(string)" production \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow \
  -vvv

echo "Merging admitted vaults into deployments/production.json ..."
node <<'NODE'
const fs = require('fs');
const addCfg = require('./script/config/add-vaults-production.json');
const path = './deployments/production.json';
const dep = JSON.parse(fs.readFileSync(path, 'utf8'));
const existing = new Set(dep.vaultAddresses.map((a) => a.toLowerCase()));

const protocolOrder = ['aave', 'morpho', 'eulerEVault', 'eulerEarn', 'capyfi'];
for (const protocol of protocolOrder) {
  const rows = addCfg.vaults[protocol] || [];
  const adapter = addCfg.adapters[protocol];
  for (const row of rows) {
    const vault = row.vault;
    if (existing.has(vault.toLowerCase())) continue;
    dep.vaultAddresses.push(vault);
    dep.vaultKinds.push(protocol);
    dep.vaultAdapters.push(adapter);
    dep.vaultCanDeposit.push(row.canDeposit);
    dep.vaultCanRedeem.push(row.canRedeem);
    existing.add(vault.toLowerCase());
  }
}

fs.writeFileSync(path, JSON.stringify(dep, null, 2) + '\n');
console.log('Updated', path, '— vaultCount now', dep.vaultAddresses.length);
NODE
