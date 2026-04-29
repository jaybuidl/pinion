#!/usr/bin/env bash

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

arbitratorGenesisBlock=15485755
network=ethereum
output=metaevidence-${network}.json

# Pull MetaEvidence events from genesis and shape each log into one JSON row.
cast logs 0x61606860eb6c87306811e2695215385101daab53bd6ab4e9f9049aead9363c7d \
  --from-block $arbitratorGenesisBlock \
  --rpc-url "$RPC_URL" \
  --json | jq -c '.[]' | while read -r row; do
  # topics[1] stores metaEvidenceID, while data contains the ABI-encoded evidence URI.
  meta_evidence_id=$(cast to-dec "$(jq -r '.topics[1]' <<<"$row")")
  data=$(jq -r '.data' <<<"$row")
  evidence=$(cast abi-decode "f()(string)" "$data" | sed 's/^"//; s/"$//')
  block_dec=$(cast to-dec "$(jq -r '.blockNumber' <<<"$row")")

  # Keep fields explicit to make downstream post-processing deterministic.
  jq -n \
    --arg     addr "$(jq -r '.address' <<<"$row")" \
    --argjson bn   "$block_dec" \
    --arg     tx   "$(jq -r '.transactionHash' <<<"$row")" \
    --arg     meid "$meta_evidence_id" \
    --arg     ev   "$evidence" \
    '{
      address: $addr,
      blockNumber: $bn,
      transactionHash: $tx,
      metaEvidenceID: $meid,
      evidence: $ev
    }'
done | jq -s '.' | tee $output

# Build an enriched copy first, then replace $output atomically.
tmp_output=$(mktemp)

jq -c '.[]' "$output" | while read -r row; do
  # On reruns, skip network work for rows that were already enriched.
  if jq -e 'has("fileURI") and has("dynamicScriptURI") and has("evidenceDisplayInterfaceURI")' >/dev/null 2>&1 <<<"$row"; then
    jq -c '.' <<<"$row"
    continue
  fi

  evidence_uri=$(jq -r '.evidence // empty' <<<"$row")
  file_uri=null
  dynamic_script_uri=null
  evidence_display_interface_uri=null
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
      dynamic_script_uri=$(jq -c '.dynamicScriptURI // null' <<<"$fetched_payload")
      evidence_display_interface_uri=$(jq -c '.evidenceDisplayInterfaceURI // null' <<<"$fetched_payload")
    fi
  fi

  jq -c \
    --argjson fileURI "$file_uri" \
    --argjson dynamicScriptURI "$dynamic_script_uri" \
    --argjson evidenceDisplayInterfaceURI "$evidence_display_interface_uri" \
    '. + {
      fileURI: $fileURI,
      dynamicScriptURI: $dynamicScriptURI,
      evidenceDisplayInterfaceURI: $evidenceDisplayInterfaceURI
    }' <<<"$row"
done | jq -s '.' > "$tmp_output"

# Replace output only once the full enriched JSON is ready.
mv "$tmp_output" "$output"

# Export all distinct arbitrable addresses seen in MetaEvidence events.
jq -r '[.[].address] | unique | .[]' $output | tee unique-arbitrables-from-metaevidence-${network}.json

# Show some statistics.
echo -n "Unique metaevidence: "
jq '[.[].evidence] | unique | length' $output
echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' $output


