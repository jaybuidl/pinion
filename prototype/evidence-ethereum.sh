#!/usr/bin/env bash

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

arbitratorGenesisBlock=15485755
network=ethereum
output=evidence-${network}.json

# Pull Evidence events from genesis and shape each log into one JSON row.
cast logs 0xdccf2f8b2cc26eafcd61905cba744cff4b81d14740725f6376390dc6298a6a3c \
  --from-block $arbitratorGenesisBlock \
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
done | jq -s '.' | tee $output

# Build an enriched copy first, then replace $output atomically.
tmp_output=$(mktemp)

jq -c '.[]' "$output" | while read -r row; do
  # On reruns, skip network work for rows that were already enriched.
  if jq -e 'has("fileURI")' >/dev/null 2>&1 <<<"$row"; then
    jq -c '.' <<<"$row"
    continue
  fi

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

  if [[ -n "$normalized_uri" ]]; then
    # Network and JSON parsing failures should not abort the whole script.
    fetched_payload=$(curl -fsSL "https://cdn.kleros.link/ipfs/$normalized_uri" 2>/dev/null || true)
    if [[ -n "$fetched_payload" ]] && jq -e . >/dev/null 2>&1 <<<"$fetched_payload"; then
      file_uri=$(jq -c '.fileURI // null' <<<"$fetched_payload")
    fi
  fi

  jq -c \
    --argjson fileURI "$file_uri" \
    '. + { fileURI: $fileURI }' <<<"$row"
done | jq -s '.' > "$tmp_output"

# Replace output only once the full enriched JSON is ready.
mv "$tmp_output" "$output"

# Export all distinct arbitrable addresses seen in Evidence events.
jq -r '[.[].address] | unique | .[]' $output | tee unique-arbitrables-from-evidence-${network}.json

# Show some statistics.
echo -n "Unique evidence: "
jq '[.[].evidence] | unique | length' $output
echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' $output

