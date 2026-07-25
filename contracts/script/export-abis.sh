#!/usr/bin/env bash
# Exports the ABIs the TypeScript rails consume into the repo-level abis/ directory.
# Run from the repository root: bash contracts/script/export-abis.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${ROOT}/abis"

cd "${ROOT}/contracts"
forge build >/dev/null

mkdir -p "${OUT}"

emit() {
    local contract="$1"
    local artifact="out/${contract}.sol/${contract}.json"
    if [ ! -f "${artifact}" ]; then
        echo "missing artifact: ${artifact}" >&2
        exit 1
    fi
    jq '.abi' "${artifact}" > "${OUT}/${contract}.json"
    echo "wrote abis/${contract}.json"
}

emit PartyVault
emit ICarryAdapter

# Emitted only once the adapter lands (POO-1060).
if [ -f "out/AaveV3Adapter.sol/AaveV3Adapter.json" ]; then
    emit AaveV3Adapter
fi
