#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

helm --kube-context app upgrade --install cnpg \
  oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --wait --version 0.25.0 --timeout 10m \
  -f "$ROOT/cnpg-operator-values.yaml"

kubectl --context app create namespace vmks --dry-run=client -o yaml \
  | kubectl --context app apply -f -
kubectl --context app apply -f "$ROOT/manifests/cnpg/cluster.yaml"

kubectl --context app -n vmks wait --for=condition=Ready cluster/pg-grafana --timeout=10m

PRIMARY="$(kubectl --context app -n vmks get cluster pg-grafana -o jsonpath='{.status.currentPrimary}')"
kubectl --context app -n vmks exec "$PRIMARY" -c postgres -- \
  psql -U postgres -d postgres -c "ALTER DATABASE grafana OWNER TO app;"
