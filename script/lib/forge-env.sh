#!/usr/bin/env bash
# Shared setup for Foundry deploy/verify scripts in this repo.
# Sources smart-contracts/.env (gitignored) and uses an encrypted cast keystore account.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

load_env_private_key() {
  local var_name="$1"
  local env_file="$2"
  if [ ! -f "$env_file" ]; then
    return 1
  fi
  local value
  value="$(grep -E "^${var_name}=" "$env_file" | head -1 | cut -d= -f2- | tr -d '\r"' | xargs)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

# Reuse grow-backend deployer when no Foundry keystore is configured locally.
if [ -z "${DEPLOYMENT_WALLET_PRIVATE_KEY:-}" ] && [ -f ../grow-backend/.env ]; then
  DEPLOYMENT_WALLET_PRIVATE_KEY="$(
    load_env_private_key RELAYER_FACTORY_DEPLOY_PRIVATE_KEY ../grow-backend/.env \
      || load_env_private_key DEPLOYMENT_WALLET_PRIVATE_KEY ../grow-backend/.env
  )"
  export DEPLOYMENT_WALLET_PRIVATE_KEY
fi

export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export FOUNDRY_ACCOUNT="${FOUNDRY_ACCOUNT:-grow-deployer}"
export GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD)}"

if [ -z "${BASESCAN_API_KEY:-}" ] && [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  export BASESCAN_API_KEY="$ETHERSCAN_API_KEY"
fi
if [ -z "${ETHERSCAN_API_KEY:-}" ] && [ -n "${BASESCAN_API_KEY:-}" ]; then
  export ETHERSCAN_API_KEY="$BASESCAN_API_KEY"
fi

require_foundry_account() {
  if ! cast wallet address --account "$FOUNDRY_ACCOUNT" >/dev/null 2>&1; then
    echo "Foundry keystore account '${FOUNDRY_ACCOUNT}' not found." >&2
    echo "Import once (encrypted keystore, not plaintext in .env):" >&2
    echo "  cast wallet import ${FOUNDRY_ACCOUNT} --interactive" >&2
    exit 1
  fi
}

deployer_address() {
  if cast wallet address --account "$FOUNDRY_ACCOUNT" >/dev/null 2>&1; then
    cast wallet address --account "$FOUNDRY_ACCOUNT"
    return
  fi
  if [ -n "${DEPLOYMENT_WALLET_PRIVATE_KEY:-}" ]; then
    cast wallet address --private-key "$DEPLOYMENT_WALLET_PRIVATE_KEY"
    return
  fi
  echo "No deployer: import ${FOUNDRY_ACCOUNT} or set DEPLOYMENT_WALLET_PRIVATE_KEY" >&2
  exit 1
}

require_deployer() {
  deployer_address >/dev/null
}

forge_broadcast_args() {
  if cast wallet address --account "$FOUNDRY_ACCOUNT" >/dev/null 2>&1; then
    echo "--account" "$FOUNDRY_ACCOUNT"
    return
  fi
  if [ -n "${DEPLOYMENT_WALLET_PRIVATE_KEY:-}" ]; then
    echo "--private-key" "$DEPLOYMENT_WALLET_PRIVATE_KEY"
    return
  fi
  echo "No deployer: import ${FOUNDRY_ACCOUNT} or set DEPLOYMENT_WALLET_PRIVATE_KEY" >&2
  exit 1
}
