#!/usr/bin/env bash
# Regenerate contracts/abi/*.json: the ABIs of the contracts the app calls, from the production (default profile,
# solc 0.8.28) build. app/tests/abi-drift.test.mts compares the app's hand-written ABIs against these snapshots, so CI
# needs no forge. Run after any change to a contract's external interface, and commit the result:
#
#   cd contracts && script/export-abis.sh          # forge build, then write abi/*.json
#   cd contracts && script/export-abis.sh --check  # fail if abi/*.json is out of date (CI with forge)
set -euo pipefail

cd "$(dirname "$0")/.."            # contracts/

# Contract name → source file (relative to src/).
CONTRACTS=(
  "MiyaRegistry:registry/MiyaRegistry.sol"
  "UniAlignmentVault:vaults/uni/UniAlignmentVault.sol"
  "UniAlignmentVaultFactory:vaults/uni/UniAlignmentVaultFactory.sol"
  "ERC721DropFactory:factories/erc721drop/ERC721DropFactory.sol"
  "ERC721DropInstance:factories/erc721drop/ERC721DropInstance.sol"
  "ERC721AuctionFactory:factories/erc721/ERC721AuctionFactory.sol"
  "ERC721AuctionInstance:factories/erc721/ERC721AuctionInstance.sol"
  "ERC1155Factory:factories/erc1155/ERC1155Factory.sol"
  "ERC1155Instance:factories/erc1155/ERC1155Instance.sol"
  "MiyaPoolFactory:pools/MiyaPoolFactory.sol"
  "MiyaPool:pools/MiyaPool.sol"
)

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

FOUNDRY_PROFILE=default forge build >/dev/null 2>&1 || FOUNDRY_PROFILE=default forge build

OUT_DIR="abi"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for entry in "${CONTRACTS[@]}"; do
  name="${entry%%:*}"
  file="$(basename "${entry#*:}")"
  artifact="out/${file}/${name}.json"
  [ -f "$artifact" ] || { echo "export-abis.sh: missing $artifact" >&2; exit 1; }
  # Sorted, so the snapshot only changes when the interface does.
  jq 'def key: [.type, (.name // ""), ([.inputs[]?.type] | join(","))]; .abi | sort_by(key)' "$artifact" > "$TMP/${name}.json"
done

if [ "$CHECK" = 1 ]; then
  if ! diff -r "$OUT_DIR" "$TMP" >/dev/null 2>&1; then
    diff -r "$OUT_DIR" "$TMP" | head -40 >&2 || true
    echo "export-abis.sh: contracts/abi is out of date: run script/export-abis.sh and commit it" >&2
    exit 1
  fi
  echo "contracts/abi is up to date"
else
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  cp "$TMP"/*.json "$OUT_DIR"/
  echo "wrote ${#CONTRACTS[@]} ABIs to contracts/${OUT_DIR}/"
fi
