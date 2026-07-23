#!/usr/bin/env bash
# Verify GrowYield production deployment on Basescan (chain 8453).
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

export ETHERSCAN_API_KEY="$(read_env BASESCAN_API_KEY)"
if [ -z "${ETHERSCAN_API_KEY}" ]; then
  export ETHERSCAN_API_KEY="$(read_env ETHERSCAN_API_KEY)"
fi

if [ -z "${ETHERSCAN_API_KEY}" ]; then
  echo "Set BASESCAN_API_KEY or ETHERSCAN_API_KEY in grow-backend/.env" >&2
  exit 1
fi

EXECUTOR=0xA25156b33dF41D2199671625Bf2314e0A1a31b9D
COMMON=(--chain base --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --watch)

verify() {
  local address=$1
  local spec=$2
  shift 2
  echo "Verifying $spec at $address ..."
  forge verify-contract "$address" "$spec" "${COMMON[@]}" "$@"
}

verify 0x088Da052247C69B52482179a56B3a96398D3139c script/GrowYieldDeployer.sol:GrowYieldDeployer

verify "$EXECUTOR" src/GrowYieldExecutor.sol:GrowYieldExecutor \
  --constructor-args "$(cast abi-encode "constructor(uint16,address)" 50 0xe8D212F886109cbf01e8294E3640a6Fb05544ff3)"

verify 0x49246E8e7C0F0479Dd208039290FDb21B94E8429 src/GrowYieldPolicyModule.sol:GrowYieldPolicyModule \
  --constructor-args "$(cast abi-encode "constructor(address,address,uint128,uint128,uint256,uint128,uint128,uint128,uint128)" \
    "$EXECUTOR" 0x00000000000667F27D4DB42334ec11a25db7EBb4 500000 2000000 150000 200000 200000 2000000000 2000000000)"

verify 0x47f181316C96ee9045c7f5eFfACa47C23658478a src/adapters/AaveV3Adapter.sol:AaveV3Adapter \
  --constructor-args "$(cast abi-encode "constructor(address,address,address,address)" \
    0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "$EXECUTOR")"

verify 0xC100691d7a8421477bE09CCC0F4d185144E2d085 src/adapters/MorphoVaultV2Adapter.sol:MorphoVaultV2Adapter \
  --constructor-args "$(cast abi-encode "constructor(address,address,address,address,address)" \
    0xa157a87D41ef25d033082180858DB0813ad61d39 0x4501125508079A99ebBebCE205DeC9593C2b5857 0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642 0x006A9c616E87F10635896D3B16D1E6922B5Ace16 "$EXECUTOR")"

verify 0x21490160229E4d9586cfF8D9537b6fCbB4FF4Af0 src/adapters/EulerEVaultAdapter.sol:EulerEVaultAdapter \
  --constructor-args "$(cast abi-encode "constructor(address,address,address,address)" \
    0x7F321498A801A191a93C840750ed637149dDf8D0 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "$EXECUTOR")"

verify 0xbBa5E40133Df5Bdf89C01c5794ec24bDc5B96Cc8 src/adapters/EulerEarnAdapter.sol:EulerEarnAdapter \
  --constructor-args "$(cast abi-encode "constructor(address,address,address,address)" \
    0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6 0x1c66B3A163e1998D9235E24e782d3d54aDEa094E 0x8bF41Ad2b816F7c220b22F4BCD63fC2A35Ab4247 "$EXECUTOR")"

verify 0x9A918b6B3BF86Da156B1CD1571e4cab4CDbdbc1b src/adapters/CapyFiAdapter.sol:CapyFiAdapter \
  --constructor-args "$(cast abi-encode "constructor(address,address,address,address)" \
    "$EXECUTOR" 0x00dc4965916e03A734190fA382633657c71f867E 0x5aDb71adb317CE975A405e90335068F0aF9F26C7 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)"

REGISTRY_ARGS=$(cast abi-encode "constructor(address,(address,bool,bool)[])" "$EXECUTOR" \
  "[(0x47f181316C96ee9045c7f5eFfACa47C23658478a,true,true),(0xC100691d7a8421477bE09CCC0F4d185144E2d085,true,true),(0x21490160229E4d9586cfF8D9537b6fCbB4FF4Af0,true,true),(0xbBa5E40133Df5Bdf89C01c5794ec24bDc5B96Cc8,true,true),(0x9A918b6B3BF86Da156B1CD1571e4cab4CDbdbc1b,true,true)]")

verify 0xC797FDb0241f078a58A37999f7B790dC2D1C951e src/GrowYieldAdapterRegistry.sol:GrowYieldAdapterRegistry \
  --constructor-args "$REGISTRY_ARGS"

echo "All production contracts submitted for Basescan verification."
