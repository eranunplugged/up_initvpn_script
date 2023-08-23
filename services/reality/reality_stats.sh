#!/bin/bash
XRAY=/opt/xray/xray

[ -x $XRAY ] || exit 1
DL=$($XRAY api stats -name "inbound>>>reality>>>traffic>>>downlink" | jq -r .stat.value)
UP=$($XRAY api stats -name "inbound>>>reality>>>traffic>>>uplink" | jq -r .stat.value)

OUT=$(echo "{}" | jq --arg dl $DL --arg up $UP --arg hostname $HOSTNAME '. + {reality_downlink: $dl, reality_uplink: $up, host: $hostname}')
# shellcheck disable=SC2086
logger $OUT