#!/usr/bin/env bash

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

arbitratorGenesisBlock=16895601
network=gnosis
output=evidence-${network}.json

cast logs 0xdccf2f8b2cc26eafcd61905cba744cff4b81d14740725f6376390dc6298a6a3c \
  --from-block $arbitratorGenesisBlock \
  --rpc-url "$RPC_URL" \
  --json | jq -c '.[]' | while read -r row; do
  arbitrator=$(cast parse-bytes32-address "$(jq -r '.topics[1]' <<<"$row")")
  data=$(jq -r '.data' <<<"$row")
  evidence=$(cast abi-decode "f()(string)" "$data" | sed 's/^"//; s/"$//')
  block_dec=$(cast to-dec "$(jq -r '.blockNumber' <<<"$row")")

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

jq -r '[.[].address] | unique | .[]' $output | tee unique-arbitrables-from-evidence-${network}.json

echo -n "Unique evidence: "
jq '[.[].evidence] | unique | length' $output

echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' $output
