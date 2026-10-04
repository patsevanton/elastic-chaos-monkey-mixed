#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STEP="${STEP_SECONDS:-120}"
QUIET="${QUIET_SECONDS:-300}"
KILL_EVERY="${KILL_EVERY:-30}"

cleanup() {
  for ctx in elastic app; do
    kubectl --context "$ctx" delete podchaos,networkchaos --all -A --ignore-not-found || true
  done
  if [ -f "$ROOT/.state/zone-isolate.env" ]; then
    # restore-zone.sh сам удаляет state при успехе. При сбое state сохраняем,
    # чтобы зону можно было починить вручную (rm -f здесь терял бы откат).
    "$ROOT/scripts/restore-zone.sh" || {
      echo "restore-zone.sh не удался — state $ROOT/.state/zone-isolate.env сохранён для ручного восстановления" >&2
    }
  fi
}
trap cleanup EXIT

# Перед началом работ: если остался state от прошлого прогона — восстановить зону.
# State удаляет только успешный restore-zone.sh (и это единственный удаляющий его
# путь); при сбое restore прогон прерываем, чтобы state остался для ручного отката.
preflight_state() {
  local sf="$ROOT/.state/zone-isolate.env"
  [ -f "$sf" ] || return 0
  echo "найден $sf от прошлого прогона"
  if "$ROOT/scripts/restore-zone.sh"; then
    echo "зона восстановлена, state очищен"
  else
    echo "restore не удался — state $sf сохранён, прогон прерван" >&2
    exit 1
  fi
}
preflight_state

# На каждый chaos-шаг — отдельная пара start/end на каждую цель:
# elastic master (ns elastic), elastic data (ns elastic), loadgen (ns load).
# Текст: "<step> <phase> <цель> zone-a", тег цели — target-<slug>.
CHAOS_TARGETS=("elastic master:elastic-master" "elastic data:elastic-data" "loadgen:loadgen")

annotate() {
  local zone="$1" step="$2" phase="$3"
  local short="zone-${zone##*-}"
  local t words slug
  for t in "${CHAOS_TARGETS[@]}"; do
    words="${t%%:*}"; slug="${t##*:}"
    "$ROOT/scripts/annotate-grafana.sh" "$step $phase $words $short" chaos "$step" "$zone" "$phase" "target-$slug"
  done
}

apply_zone() {
  local file="$1" zone="$2" ctx="$3"
  ZONE="$zone" envsubst < "$file" | kubectl --context "$ctx" apply -f -
}

delete_crs() {
  kubectl --context elastic -n elastic delete podchaos,networkchaos --all --ignore-not-found
  kubectl --context app -n load delete podchaos,networkchaos --all --ignore-not-found
}

quiet() {
  delete_crs
  local start=$SECONDS
  kubectl --context elastic -n elastic wait --for=jsonpath='{.status.health}'=green elasticsearch/elastic --timeout=120s || true
  kubectl --context app -n load rollout status deployment/loadgen --timeout=120s || true
  local left=$((QUIET - (SECONDS - start)))
  if [ "$left" -gt 0 ]; then sleep "$left"; fi
}

pod_kill() {
  local zone="$1" start=$SECONDS
  while [ $((SECONDS - start)) -lt "$STEP" ]; do
    apply_zone "$ROOT/manifests/chaos/pod-kill.yaml" "$zone" elastic
    apply_zone "$ROOT/manifests/chaos/pod-kill-loadgen.yaml" "$zone" app
    sleep "$KILL_EVERY"
  done
}

hold() {
  local zone="$1" esf="$2" appf="$3"
  apply_zone "$esf" "$zone" elastic
  apply_zone "$appf" "$zone" app
  sleep "$STEP"
}

zone=ru-central1-a
echo "zone $zone pod-kill"
annotate "$zone" pod-kill start
pod_kill "$zone"
annotate "$zone" pod-kill end
quiet
echo "zone $zone loss"
annotate "$zone" loss start
hold "$zone" "$ROOT/manifests/chaos/network-loss.yaml" "$ROOT/manifests/chaos/network-loss-loadgen.yaml"
annotate "$zone" loss end
quiet
echo "zone $zone delay"
annotate "$zone" delay start
hold "$zone" "$ROOT/manifests/chaos/network-delay.yaml" "$ROOT/manifests/chaos/network-delay-loadgen.yaml"
annotate "$zone" delay end
quiet
echo "zone $zone isolate"
annotate "$zone" isolate start
"$ROOT/scripts/isolate-zone.sh" "$zone"
sleep "$STEP"
"$ROOT/scripts/restore-zone.sh"
annotate "$zone" isolate end
quiet
