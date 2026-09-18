#!/usr/bin/env bash
set -euo pipefail
ID="$(kubectl get nodes -l topology.kubernetes.io/zone=ru-central1-b -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)"
ID="${ID##*/}"
if [ -z "$ID" ]; then
  ID="$(yc compute instance list --format json | jq -r '.[] | select(.zone_id=="ru-central1-b") | select(.status=="STOPPED") | .id' | head -1)"
fi
if [ -z "$ID" ]; then
  echo "не нашли VM в ru-central1-b" >&2
  exit 1
fi
echo "start $ID"
yc compute instance start "$ID"
