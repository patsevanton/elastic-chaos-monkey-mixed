#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INGRESS_IP="$(terraform output -raw traefik_elastic_ip)"
PUBLIC_IP="$(terraform output -raw traefik_elastic_public_ip)"
kubectl --context elastic create namespace elastic --dry-run=client -o yaml | kubectl --context elastic apply -f -
kubectl --context elastic apply -f "$ROOT/manifests/eck/priorityclass.yaml"
kubectl --context elastic apply -f "$ROOT/manifests/eck/elasticsearch.yaml"
kubectl --context elastic apply -f "$ROOT/manifests/eck/kibana.yaml"
sed "s/INGRESS_IP/${PUBLIC_IP}/" "$ROOT/manifests/ingress/kibana.yaml" | kubectl --context elastic apply -f -
sed "s/INGRESS_IP/${INGRESS_IP}/" "$ROOT/manifests/ingress/elasticsearch.yaml" | kubectl --context elastic apply -f -
