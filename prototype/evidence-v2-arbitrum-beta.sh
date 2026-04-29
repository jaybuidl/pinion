#!/usr/bin/env bash

: "${RPC_URL:?RPC_URL is not set. Export it (e.g. export RPC_URL=\$(mesc url)) before running.}"

arbitratorGenesisBlock=272063086
network=arbitrum-beta
output=evidence-v2-${network}.json

cast logs 0x39935cf45244bc296a03d6aef1cf17779033ee27090ce9c68d432367ce106996 \
  --from-block $arbitratorGenesisBlock \
  --rpc-url "$RPC_URL" \
  --json | jq -c '.[]' | while read -r row; do
  external_dispute_id=$(cast to-dec "$(jq -r '.topics[1]' <<<"$row")")
  party=$(cast parse-bytes32-address "$(jq -r '.topics[2]' <<<"$row")")
  data=$(jq -r '.data' <<<"$row")
  evidence=$(cast abi-decode "f()(string)" "$data" | sed 's/^"//; s/"$//')
  block_dec=$(cast to-dec "$(jq -r '.blockNumber' <<<"$row")")

  jq -n \
    --arg     addr "$(jq -r '.address' <<<"$row")" \
    --argjson bn   "$block_dec" \
    --arg     tx   "$(jq -r '.transactionHash' <<<"$row")" \
    --arg     edid "$external_dispute_id" \
    --arg     pty  "$party" \
    --arg     ev   "$evidence" \
    '{
      address: $addr,
      blockNumber: $bn,
      transactionHash: $tx,
      externalDisputeID: $edid,
      party: $pty,
      evidence: $ev
    }'
done | jq -s '
  map(. + {
    fileURI: (
      .evidence
      | if startswith("/ipfs/") or startswith("ipfs://") then .
        else
          gsub("\\\\\""; "\"")
          | (try (fromjson | .fileURI) catch null)
        end
    )
  })
' | tee $output

jq -r '[.[].address] | unique | .[]' $output | tee unique-arbitrables-from-evidence-v2-${network}.json

echo -n "Unique evidence: "
jq '[.[].evidence] | unique | length' $output

echo -n "Unique arbitrables: "
jq '[.[].address] | unique | length' $output
