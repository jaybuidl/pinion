#!/usr/bin/env bash

set -euo pipefail

function usage() {
  echo "Usage: $0 <network>"
  echo "Supported networks: ethereum, gnosis"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

network="$1"
topic="0xdccf2f8b2cc26eafcd61905cba744cff4b81d14740725f6376390dc6298a6a3c"

case "$network" in
  ethereum) arbitratorGenesisBlock=15485755 ;;
  gnosis) arbitratorGenesisBlock=16895601 ;;
  *)
    echo "Unsupported network: $network"
    usage
    exit 1
    ;;
esac

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

output="evidence-${network}.json"

# Unavailable on CDN, no need to fetch.
blacklisted_cids=(
  "QmSGUyGqVGjs9Ran7FKyebjGcXYFyq2gpR5oMv2ovz6Wvc"
  "QmVV5TWYsWwn5u5e9yWpK1H2C93a1XgrdZ2ULHh3S4Fzed"
  "Qmdf1fwSnygpxBtURVpzgYmL7TjKQNfT9AwsFDBf7nTRJZ"
  "QmeDUxmwd1tMu7bjZ6vz5H6dYxiphhkRxmhFbPfMYR3U36"
  "QmSduCXqCxysdRBMiMomtQrdMWDDPYxiL15skSg8E7QtfH"
  "QmdYQofCFVK3BSqmYSHRKWrkmWeygtsTad8YfehBrTEazH"
)

function is_cid_blacklisted() {
  local cid="$1"
  local blacklisted_cid=
  for blacklisted_cid in "${blacklisted_cids[@]}"; do
    if [[ "$blacklisted_cid" == "$cid" ]]; then return 0; fi
  done
  return 1
}

# Pull Evidence events from genesis and shape each log into one JSON row.
cast logs "$topic" \
  --from-block "$arbitratorGenesisBlock" \
  --rpc-url "$RPC_URL" \
  --json | jq -c '.[]' | while read -r row; do
  # topics[1] stores arbitrator, while data contains the ABI-encoded evidence URI.
  arbitrator=$(cast parse-bytes32-address "$(jq -r '.topics[1]' <<<"$row")")
  data=$(jq -r '.data' <<<"$row")
  evidence=$(cast abi-decode "f()(string)" "$data" | sed 's/^"//; s/"$//')
  block_dec=$(cast to-dec "$(jq -r '.blockNumber' <<<"$row")")

  # Keep fields explicit so post-processing can safely enrich each entry.
  jq -n \
    --arg     addr "$(jq -r '.address' <<<"$row")" \
    --argjson bn   "$block_dec" \
    --arg     tx   "$(jq -r '.transactionHash' <<<"$row")" \
    --arg     arb  "$arbitrator" \
    --arg     ev   "$evidence" \
    '{
      address: $addr,
      blockNumber: $bn,
      transactionHash: $tx,
      arbitrator: $arb,
      evidence: $ev
    }'
done | jq -s '.' | tee "$output"

# Build an enriched copy first, then replace $output atomically.
tmp_output=$(mktemp)
tmp_rows=$(mktemp)
total_rows=$(jq 'length' "$output")
processed_rows=0

echo "tmp_output: $tmp_output"

while read -r row; do
  enriched_row="$row"

  # On reruns, skip network work for rows that were already enriched.
  if ! jq -e 'has("fileURI")' >/dev/null 2>&1 <<<"$row"; then
    evidence_uri=$(jq -r '.evidence // empty' <<<"$row")
    file_uri=null
    normalized_uri=

    # Normalize common IPFS URI formats to the gateway path segment.
    if [[ "$evidence_uri" == ipfs://* ]]; then
      normalized_uri="${evidence_uri#ipfs://}"
    elif [[ "$evidence_uri" == /ipfs/* ]]; then
      normalized_uri="${evidence_uri#/ipfs/}"
    elif [[ "$evidence_uri" == */ipfs/* ]]; then
      normalized_uri="${evidence_uri#*/ipfs/}"
    elif [[ -n "$evidence_uri" ]]; then
      normalized_uri="$evidence_uri"
    fi
    cid_candidate="${normalized_uri%%/*}"
    if [[ -n "$normalized_uri" && -n "$cid_candidate" ]] && ! is_cid_blacklisted "$cid_candidate"; then
      # Network and JSON parsing failures should not abort the whole script.
      echo "fetching normalized_uri: $normalized_uri"
      fetched_payload=$(curl -fsSL "https://cdn.kleros.link/ipfs/$normalized_uri" 2>/dev/null || true)
      if [[ -n "$fetched_payload" ]] && jq -e . >/dev/null 2>&1 <<<"$fetched_payload"; then
        file_uri=$(jq -c '.fileURI // null' <<<"$fetched_payload")
      fi
    fi

    enriched_row=$(jq -c \
      --argjson fileURI "$file_uri" \
      '. + { fileURI: $fileURI }' <<<"$row")
  fi

  echo "$enriched_row" >> "$tmp_rows"
  ((processed_rows += 1))
  progress_pct=100
  if (( total_rows > 0 )); then progress_pct=$((processed_rows * 100 / total_rows)); fi
  printf "\rEnrichment progress: %d/%d (%d%%)" "$processed_rows" "$total_rows" "$progress_pct"
done < <(jq -c '.[]' "$output")

printf "\n"
jq -s '.' "$tmp_rows" > "$tmp_output"
rm -f "$tmp_rows"

# Replace output only once the full enriched JSON is ready.
mv "$tmp_output" "$output"

# Export all distinct arbitrable addresses seen in Evidence events.
jq -r '[.[].address] | unique | .[]' "$output" | tee "unique-arbitrables-from-evidence-${network}.json"

# Show some statistics.
echo -n "Unique evidence: "
jq '[.[].evidence] | unique | length' "$output"
echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' "$output"
