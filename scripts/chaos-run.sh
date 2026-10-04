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
    "$ROOT/scripts/restore-zone.sh" || rm -f "$ROOT/.state/zone-isolate.env"
  fi
}
trap cleanup EXIT

# Перед началом работ: если остался state от прошлого прогона — восстановить
# зону; если state stale/невалиден — удалить, чтобы isolate-zone.sh не упал.
preflight_state() {
  local sf="$ROOT/.state/zone-isolate.env"
  [ -f "$sf" ] || return 0
  echo "найден $sf от прошлого прогона"
  if "$ROOT/scripts/restore-zone.sh"; then
    echo "зона восстановлена, state очищен"
  else
    echo "restore не удался (stale state) — удаляю $sf" >&2
    rm -f "$sf"
  fi
}
preflight_state

annotate() {
  local zone="$1" step="$2" phase="$3"
  "$ROOT/scripts/annotate-grafana.sh" "zone $zone: $step $phase" chaos "$step" "$zone" "$phase"
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
