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
topic="0x61606860eb6c87306811e2695215385101daab53bd6ab4e9f9049aead9363c7d"

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

output="metaevidence-${network}.json"
blacklisted_cids=()

function is_cid_blacklisted() {
  local cid="$1"
  local blacklisted_cid=
  for blacklisted_cid in "${blacklisted_cids[@]}"; do
    if [[ "$blacklisted_cid" == "$cid" ]]; then return 0; fi
  done
  return 1
}

function normalize_ipfs_uri() {
  local uri="$1"
  local normalized_uri="$uri"

  if [[ "$normalized_uri" == ipfs://ipfs/* ]]; then
    normalized_uri="${normalized_uri#ipfs://ipfs/}"
  elif [[ "$normalized_uri" == ipfs://* ]]; then
    normalized_uri="${normalized_uri#ipfs://}"
  elif [[ "$normalized_uri" == /ipfs/* ]]; then
    normalized_uri="${normalized_uri#/ipfs/}"
  elif [[ "$normalized_uri" == */ipfs/* ]]; then
    normalized_uri="${normalized_uri#*/ipfs/}"
  fi

  echo "$normalized_uri"
}

function extract_cid_from_uri() {
  local uri="$1"
  local normalized_uri=
  local cid_candidate=

  normalized_uri="$(normalize_ipfs_uri "$uri")"
  cid_candidate="${normalized_uri%%/*}"
  cid_candidate="${cid_candidate%%\?*}"
  cid_candidate="${cid_candidate%%\#*}"

  if [[ -z "$cid_candidate" ]]; then return 1; fi
  echo "$cid_candidate"
}

function is_cid_seen() {
  local cid="$1"
  local seen_cid=
  for seen_cid in "${seen_cids[@]}"; do
    if [[ "$seen_cid" == "$cid" ]]; then return 0; fi
  done
  return 1
}

# Pull MetaEvidence events from genesis and shape each log into one JSON row.
cast logs "$topic" \
  --from-block "$arbitratorGenesisBlock" \
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
done | jq -s '.' | tee "$output"

# Build an enriched copy first, then replace $output atomically.
tmp_output=$(mktemp)
tmp_rows=$(mktemp)
total_rows=$(jq 'length' "$output")
processed_rows=0

while read -r row; do
  enriched_row="$row"

  # On reruns, skip network work for rows that were already enriched.
  if ! jq -e 'has("fileURI") and has("dynamicScriptURI") and has("evidenceDisplayInterfaceURI")' >/dev/null 2>&1 <<<"$row"; then
    evidence_uri=$(jq -r '.evidence // empty' <<<"$row")
    file_uri=null
    dynamic_script_uri=null
    evidence_display_interface_uri=null
    normalized_uri="$(normalize_ipfs_uri "$evidence_uri")"
    cid_candidate="$(extract_cid_from_uri "$evidence_uri" 2>/dev/null || true)"
    if [[ -n "$normalized_uri" && -n "$cid_candidate" ]] && ! is_cid_blacklisted "$cid_candidate"; then
      # Network and JSON parsing failures should not abort the whole script.
      fetched_payload=$(curl -fsSL "https://cdn.kleros.link/ipfs/$normalized_uri" 2>/dev/null || true)
      if [[ -n "$fetched_payload" ]] && jq -e . >/dev/null 2>&1 <<<"$fetched_payload"; then
        file_uri=$(jq -c '.fileURI // null' <<<"$fetched_payload")
        dynamic_script_uri=$(jq -c '.dynamicScriptURI // null' <<<"$fetched_payload")
        evidence_display_interface_uri=$(jq -c '.evidenceDisplayInterfaceURI // null' <<<"$fetched_payload")
      fi
    fi

    enriched_row=$(jq -c \
      --argjson fileURI "$file_uri" \
      --argjson dynamicScriptURI "$dynamic_script_uri" \
      --argjson evidenceDisplayInterfaceURI "$evidence_display_interface_uri" \
      '. + {
        fileURI: $fileURI,
        dynamicScriptURI: $dynamicScriptURI,
        evidenceDisplayInterfaceURI: $evidenceDisplayInterfaceURI
      }' <<<"$row")
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

# Pin all distinct CIDs found in metaevidence fields through Filebase RPC.
: "${BEARER:?BEARER is not set. Export it before running this script.}"
seen_cids=()
pinned_count=0
failed_count=0

while read -r row; do
  while read -r maybe_uri; do
    if [[ -z "$maybe_uri" ]]; then continue; fi

    cid_candidate="$(extract_cid_from_uri "$maybe_uri" 2>/dev/null || true)"
    if [[ -z "$cid_candidate" ]] || is_cid_blacklisted "$cid_candidate" || is_cid_seen "$cid_candidate"; then
      continue
    fi

    seen_cids+=("$cid_candidate")
    if curl -fsS -X POST -H "Authorization: Bearer $BEARER" "https://rpc.filebase.io/api/v0/pin/add?arg=$cid_candidate" >/dev/null 2>&1; then
      ((pinned_count += 1))
      echo "Pinned CID: $cid_candidate"
    else
      ((failed_count += 1))
      echo "Failed to pin CID: $cid_candidate"
    fi
  done < <(jq -r '.evidence // empty, .fileURI // empty, .dynamicScriptURI // empty, .evidenceDisplayInterfaceURI // empty' <<<"$row")
done < <(jq -c '.[]' "$output")

echo "Pinning complete. Success: $pinned_count, Failed: $failed_count, Unique CIDs seen: ${#seen_cids[@]}"

# Export all distinct arbitrable addresses seen in MetaEvidence events.
jq -r '[.[].address] | unique | .[]' "$output" | tee "unique-arbitrables-from-metaevidence-${network}.json"

# Show some statistics.
echo -n "Unique metaevidence: "
jq '[.[].evidence] | unique | length' "$output"
echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' "$output"
