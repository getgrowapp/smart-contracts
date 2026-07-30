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
  cast wallet address --account "$FOUNDRY_ACCOUNT"
}
