#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATE_FILE="$ROOT/.state/zone-isolate.env"
if [ ! -f "$STATE_FILE" ]; then
  echo "нет $STATE_FILE" >&2
  exit 1
fi
ZONE="" ELASTIC_MASTER_NG="" ELASTIC_DATA_NG="" APP_NG="" ELASTIC_MASTER_SG="" ELASTIC_DATA_SG="" APP_SG=""
# shellcheck disable=SC1090
source "$STATE_FILE"
if [ -z "$ZONE" ] || [ -z "$ELASTIC_MASTER_NG" ] || [ -z "$ELASTIC_DATA_NG" ] || [ -z "$APP_NG" ]; then
  echo "state неполный" >&2
  exit 1
fi
if [ "$ZONE" != "ru-central1-a" ]; then
  echo "восстанавливаем только ru-central1-a, а не $ZONE" >&2
  exit 1
fi

restore_ng() {
  local ng="$1" sg="$2"
  local subnets
  subnets="$(yc managed-kubernetes node-group get "$ng" --format json | jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")')"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: restore SG $ng start" sg isolate "$ZONE" "$ng" start
  if [ -n "$sg" ]; then
    yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets},security-group-ids=[${sg}]"
  else
    yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets}"
  fi
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: restore SG $ng end" sg isolate "$ZONE" "$ng" end
}

pids=()
restore_ng "$ELASTIC_MASTER_NG" "$ELASTIC_MASTER_SG" & pids+=("$!")
restore_ng "$ELASTIC_DATA_NG" "$ELASTIC_DATA_SG" & pids+=("$!")
restore_ng "$APP_NG" "$APP_SG" & pids+=("$!")
fail=0
for p in "${pids[@]}"; do
  if ! wait "$p"; then fail=1; fi
done
if [ "$fail" -ne 0 ]; then
  echo "один или несколько node-group update не удались" >&2
  exit 1
fi
rm -f "$STATE_FILE"
echo "zone $ZONE restored"
