#!/usr/bin/env bash
#
# Runs a command against a FRESH Anvil fork of Arbitrum, then tears it down.
#
# Why fresh every time, rather than one long-lived fork: Anvil pins the fork block at startup
# and fetches state lazily from upstream. Public Arbitrum RPCs are not archive nodes, so once
# the pinned block ages out of their retention the fork starts failing mid-run with
#   -32000: metadata is not found
# on any account it has not already cached. A fork that has been up for hours is a fork that
# is about to break in a way that looks like a bug in our code.
#
# Usage: scripts/with-fork.sh pnpm rehearse
set -euo pipefail

PORT="${FORK_PORT:-8545}"
RPC="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"
LOG="$(mktemp -t anvil-fork)"

if lsof -i ":${PORT}" >/dev/null 2>&1; then
  echo "Port ${PORT} is already in use. Reusing whatever is listening there."
  echo "If that is a stale fork, stop it first: pkill -f 'anvil --fork-url'"
  exec "$@"
fi

echo "Starting Anvil fork of Arbitrum on port ${PORT} (log: ${LOG})"
anvil --fork-url "${RPC}" --port "${PORT}" --silent >"${LOG}" 2>&1 &
ANVIL_PID=$!

cleanup() {
  if kill -0 "${ANVIL_PID}" 2>/dev/null; then
    echo "Stopping Anvil fork (pid ${ANVIL_PID})"
    kill "${ANVIL_PID}" 2>/dev/null || true
    wait "${ANVIL_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 40); do
  if cast block-number --rpc-url "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    echo "Fork ready at block $(cast block-number --rpc-url "http://127.0.0.1:${PORT}")"
    break
  fi
  sleep 1
done

if ! cast block-number --rpc-url "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
  echo "Anvil did not come up within 40s. Log:" >&2
  cat "${LOG}" >&2
  exit 1
fi

"$@"
