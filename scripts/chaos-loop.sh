#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RALLY_IP="$(terraform output -raw rally_internal_ip)"
HOLD="${HOLD:-900}"

rally_alive() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "ubuntu@${RALLY_IP}" 'test -f ~/rally-ingest.pid && kill -0 "$(cat ~/rally-ingest.pid)"'
}

wait_es_ready() {
  kubectl -n elastic wait --for=condition=Ready pod -l elasticsearch.k8s.elastic.co/cluster-name=chaos --timeout=600s
}

slot=0
while rally_alive; do
  slot=$((slot + 1))
  echo "slot ${slot} pod-kill $(date -u +%H:%M:%S)"
  kubectl delete -f manifests/chaos/pod-kill.yaml --ignore-not-found
  kubectl apply -f manifests/chaos/pod-kill.yaml
  sleep 20
  wait_es_ready
  kubectl delete -f manifests/chaos/pod-kill.yaml --ignore-not-found
  rally_alive || break

  echo "slot ${slot} network-loss $(date -u +%H:%M:%S)"
  kubectl apply -f manifests/chaos/network-loss.yaml
  sleep 900
  kubectl delete -f manifests/chaos/network-loss.yaml --ignore-not-found
  sleep 60
  rally_alive || break

  echo "slot ${slot} network-delay $(date -u +%H:%M:%S)"
  kubectl apply -f manifests/chaos/network-delay.yaml
  sleep 900
  kubectl delete -f manifests/chaos/network-delay.yaml --ignore-not-found
  sleep 60
  rally_alive || break

  echo "slot ${slot} stop-zone-b $(date -u +%H:%M:%S)"
  ./scripts/stop-zone-b.sh
  sleep "${HOLD}"
  echo "slot ${slot} start-zone-b $(date -u +%H:%M:%S)"
  ./scripts/start-zone-b.sh
  wait_es_ready
done
echo "ingest finished, chaos loop stop"
