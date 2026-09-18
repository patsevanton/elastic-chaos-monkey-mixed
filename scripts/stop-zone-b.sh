#!/usr/bin/env bash
set -euo pipefail
ID="$(kubectl get nodes -l topology.kubernetes.io/zone=ru-central1-b -o jsonpath='{.items[0].spec.providerID}')"
ID="${ID##*/}"
echo "stop $ID"
yc compute instance stop "$ID"
