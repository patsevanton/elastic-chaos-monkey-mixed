#!/usr/bin/env bash
set -euo pipefail
NODE="$(kubectl get nodes -l topology.kubernetes.io/zone=ru-central1-b -o jsonpath='{.items[0].metadata.name}')"
READY="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
ID="$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}')"
ID="${ID##*/}"
IP="$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
VM="$(yc compute instance get "$ID" --format json | jq -r '.status')"
echo "node=${NODE} ready=${READY} vm=${ID} vm_status=${VM} ip=${IP}"
case "$READY" in
  False|Unknown) ;;
  *) echo "node Ready=${READY}, ожидался False или Unknown" >&2; exit 1 ;;
esac
test "$VM" = "STOPPED"
if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
  echo "node ip ${IP} answers ping" >&2
  exit 1
fi
echo "zone b down: node not Ready, VM STOPPED, ${IP} unreachable"
