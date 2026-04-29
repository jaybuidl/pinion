#!/usr/bin/env bash

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

arbitratorGenesisBlock=16895601
network=gnosis
output=metaevidence-${network}.json

cast logs 0x61606860eb6c87306811e2695215385101daab53bd6ab4e9f9049aead9363c7d \
  --from-block $arbitratorGenesisBlock \
  --rpc-url "$RPC_URL" \
  --json | jq -c '.[]' | while read -r row; do
  meta_evidence_id=$(cast to-dec "$(jq -r '.topics[1]' <<<"$row")")
  data=$(jq -r '.data' <<<"$row")
  evidence=$(cast abi-decode "f()(string)" "$data" | sed 's/^"//; s/"$//')
  block_dec=$(cast to-dec "$(jq -r '.blockNumber' <<<"$row")")

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

jq -r '[.[].address] | unique | .[]' $output | tee unique-arbitrables-from-metaevidence-${network}.json

echo -n "Unique metaevidence: "
jq '[.[].evidence] | unique | length' $output

echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' $output
