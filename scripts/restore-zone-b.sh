#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STATE_FILE="$ROOT/.state/zone-b-isolate.env"
if [ ! -f "$STATE_FILE" ]; then
  echo "нет state-файла $STATE_FILE — изоляция не применялась" >&2
  exit 1
fi

ZONE=""
NG_NAME=""
SG_IDS=""
NLB_ES_ID=""
NLB_TRAEFIK_ID=""
# shellcheck disable=SC1090
source "$STATE_FILE"

if [ -z "$ZONE" ] || [ -z "$NG_NAME" ] || [ -z "$NLB_ES_ID" ] || [ -z "$NLB_TRAEFIK_ID" ]; then
  echo "state-файл неполный: $STATE_FILE" >&2
  exit 1
fi

SUBNET_IDS="$(yc managed-kubernetes node-group get "$NG_NAME" --format json \
  | jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")')"

echo "restore ng=$NG_NAME sg=[${SG_IDS}] subnets=[${SUBNET_IDS}] nlb_es=$NLB_ES_ID nlb_traefik=$NLB_TRAEFIK_ID"

if [ -n "$SG_IDS" ]; then
  yc managed-kubernetes node-group update "$NG_NAME" --network-interface "subnets=${SUBNET_IDS},security-group-ids=[${SG_IDS}]"
else
  yc managed-kubernetes node-group update "$NG_NAME" --network-interface "subnets=${SUBNET_IDS}"
fi
yc load-balancer network-load-balancer enable-zones --id "$NLB_ES_ID" --zones "$ZONE"
yc load-balancer network-load-balancer enable-zones --id "$NLB_TRAEFIK_ID" --zones "$ZONE"

rm -f "$STATE_FILE"
echo "zone $ZONE restored: sg cleared on $NG_NAME, enable-zones on $NLB_ES_ID и $NLB_TRAEFIK_ID"
