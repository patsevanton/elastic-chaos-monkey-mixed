#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STEP="${STEP_SECONDS:-600}"
KILL_EVERY="${KILL_EVERY:-30}"

cleanup() {
  for ctx in elastic app; do
    kubectl --context "$ctx" delete podchaos,networkchaos --all -A --ignore-not-found || true
  done
  if [ -f "$ROOT/.state/zone-isolate.env" ]; then
    "$ROOT/scripts/restore-zone.sh" || true
  fi
}
trap cleanup EXIT

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
  kubectl --context elastic -n elastic wait --for=jsonpath='{.status.health}'=green elasticsearch/elastic --timeout=600s || true
  kubectl --context app -n load rollout status deployment/loadgen --timeout=600s || true
  local left=$((STEP - (SECONDS - start)))
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

report() {
  echo "--- report ---"
  kubectl --context app -n load exec deploy/loadgen -- wget -qO- http://127.0.0.1:8080/metrics | awk '/^loadgen_(bulk|search)_(ok|err)_total /{print}'
  kubectl --context elastic -n elastic exec elastic-es-master-a-0 -- curl -s http://localhost:9200/load/_count || true
  echo
}

for zone in ru-central1-a ru-central1-b ru-central1-d; do
  echo "zone $zone pod-kill"
  pod_kill "$zone"
  report
  quiet
  echo "zone $zone loss"
  hold "$zone" "$ROOT/manifests/chaos/network-loss.yaml" "$ROOT/manifests/chaos/network-loss-loadgen.yaml"
  report
  quiet
  echo "zone $zone delay"
  hold "$zone" "$ROOT/manifests/chaos/network-delay.yaml" "$ROOT/manifests/chaos/network-delay-loadgen.yaml"
  report
  quiet
  echo "zone $zone isolate"
  "$ROOT/scripts/isolate-zone.sh" "$zone"
  sleep "$STEP"
  report
  "$ROOT/scripts/restore-zone.sh"
  quiet
done
