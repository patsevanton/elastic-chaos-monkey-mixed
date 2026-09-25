#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATE_FILE="$ROOT/.state/zone-isolate.env"
if [ ! -f "$STATE_FILE" ]; then
  echo "нет $STATE_FILE" >&2
  exit 1
fi
ZONE="" ELASTIC_NG="" APP_NG="" ELASTIC_SG="" APP_SG="" NLB_TRAEFIK_ID="" NLB_VMINSERT_ID=""
# shellcheck disable=SC1090
source "$STATE_FILE"
if [ -z "$ZONE" ] || [ -z "$ELASTIC_NG" ] || [ -z "$APP_NG" ] || [ -z "$NLB_TRAEFIK_ID" ] || [ -z "$NLB_VMINSERT_ID" ]; then
  echo "state неполный" >&2
  exit 1
fi

restore_ng() {
  local ng="$1" sg="$2"
  local subnets
  subnets="$(yc managed-kubernetes node-group get "$ng" --format json | jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")')"
  if [ -n "$sg" ]; then
    yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets},security-group-ids=[${sg}]"
  else
    yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets}"
  fi
}

restore_ng "$ELASTIC_NG" "$ELASTIC_SG"
restore_ng "$APP_NG" "$APP_SG"
yc load-balancer network-load-balancer enable-zones --id "$NLB_TRAEFIK_ID" --zones "$ZONE"
yc load-balancer network-load-balancer enable-zones --id "$NLB_VMINSERT_ID" --zones "$ZONE"
rm -f "$STATE_FILE"
echo "zone $ZONE restored"
