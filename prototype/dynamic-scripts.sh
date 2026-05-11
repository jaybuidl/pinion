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

case "$network" in
  ethereum|gnosis) ;;
  *)
    echo "Unsupported network: $network"
    usage
    exit 1
    ;;
esac

input="metaevidence-${network}.json"
output="dynamic-scripts-${network}.json"
output_csv="dynamic-scripts-${network}.csv"
blacklisted_cids=()

if [[ ! -f "$input" ]]; then
  echo "Input file not found: $input"
  exit 1
fi

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

# Keep only rows that ship a non-null dynamicScriptURI; that is what we want to enrich.
jq '[.[] | select(.dynamicScriptURI != null)]' "$input" | tee "$output" >/dev/null

# Build an enriched copy first, then replace $output atomically.
tmp_output=$(mktemp)
tmp_rows=$(mktemp)
total_rows=$(jq 'length' "$output")
processed_rows=0

while read -r row; do
  enriched_row="$row"

  # On reruns, skip network work for rows that were already enriched.
  if ! jq -e 'has("category") and has("title")' >/dev/null 2>&1 <<<"$row"; then
    evidence_uri=$(jq -r '.evidence // empty' <<<"$row")
    category=null
    title=null
    normalized_uri="$(normalize_ipfs_uri "$evidence_uri")"
    cid_candidate="$(extract_cid_from_uri "$evidence_uri" 2>/dev/null || true)"
    if [[ -n "$normalized_uri" && -n "$cid_candidate" ]] && ! is_cid_blacklisted "$cid_candidate"; then
      # Network and JSON parsing failures should not abort the whole script.
      fetched_payload=$(curl -fsSL "https://cdn.kleros.link/ipfs/$normalized_uri" 2>/dev/null || true)
      if [[ -n "$fetched_payload" ]] && jq -e . >/dev/null 2>&1 <<<"$fetched_payload"; then
        category=$(jq -c '.category // null' <<<"$fetched_payload")
        title=$(jq -c '.title // null' <<<"$fetched_payload")
      fi
    fi

    enriched_row=$(jq -c \
      --argjson category "$category" \
      --argjson title "$title" \
      '. + {
        category: $category,
        title: $title
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

# Create csv
echo '"address","category","title"' >"$output_csv"
jq --raw-output '. | sort_by(.category,.address) | .[] | {category,address,title} | [ keys_unsorted[] as $k | .[$k] ] | @csv' "$output" >>"$output_csv"

# Show some statistics.
echo -n "Total dynamic-script entries: "
jq 'length' "$output"
echo -n "Unique dynamicScriptURIs: "
jq '[.[].dynamicScriptURI] | unique | length' "$output"
echo -n "Unique categories: "
jq '[.[].category] | unique | length' "$output"
echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' "$output"

