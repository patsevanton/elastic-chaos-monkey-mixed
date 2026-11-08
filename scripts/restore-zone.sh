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

wait_sg() {
  local ng="$1" want="$2" i cur
  for i in $(seq 1 120); do
    cur="$(yc managed-kubernetes node-group get "$ng" --format json | jq -r '.node_template.network_interface_specs[0].security_group_ids // [] | join(",")')"
    [ "$cur" = "$want" ] && return 0
    sleep 5
  done
  echo "$ng: SG не стал [$want] за 10 минут (сейчас [$cur])" >&2
  return 1
}

restore_ng() {
  local ng="$1" sg="$2"
  local subnets
  subnets="$(yc managed-kubernetes node-group get "$ng" --format json | jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")')"
  # Аннотация — наблюдаемость, а не часть смены SG: при изолированной зоне
  # публичный NLB может ещё слать запросы в мёртвую зону, и откат не должен
  # из-за этого останавливаться.
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: restore SG $ng start" sg isolate "$ZONE" "$ng" start || \
    echo "annotate: пропущено (restore $ng start)" >&2
  # --async: синхронный update ждёт Ready, но проверяем это отдельно ниже.
  if [ -n "$sg" ]; then
    yc managed-kubernetes node-group update "$ng" --async --network-interface "subnets=${subnets},security-group-ids=[${sg}]"
  else
    yc managed-kubernetes node-group update "$ng" --async --network-interface "subnets=${subnets}"
  fi
  wait_sg "$ng" "$sg"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: restore SG $ng end" sg isolate "$ZONE" "$ng" end || \
    echo "annotate: пропущено (restore $ng end)" >&2
}

wait_zone_ready() {
  local ctx i notready
  for ctx in elastic app; do
    for i in $(seq 1 60); do
      notready="$(kubectl --context "$ctx" get nodes -l topology.kubernetes.io/zone=ru-central1-a --no-headers 2>/dev/null | grep -cv ' Ready ' || true)"
      [ "$notready" = "0" ] && break
      sleep 5
    done
    if [ "$notready" != "0" ]; then
      echo "ctx $ctx: ноды зоны a не Ready за 5 минут" >&2
      return 1
    fi
  done
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
wait_zone_ready
rm -f "$STATE_FILE"
echo "zone $ZONE restored"
