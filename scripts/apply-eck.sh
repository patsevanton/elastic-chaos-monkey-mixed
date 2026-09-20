#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SUBNET_ID="$(terraform output -raw nlb_subnet_id)"
INGRESS_IP="$(terraform output -raw traefik_ip)"
kubectl create namespace elastic --dry-run=client -o yaml | kubectl apply -f -
sed "s/NLB_SUBNET_ID/${SUBNET_ID}/" "$ROOT/manifests/eck/elasticsearch.yaml" | kubectl apply -f -
kubectl apply -f "$ROOT/manifests/eck/kibana.yaml"
sed "s/INGRESS_IP/${INGRESS_IP}/" "$ROOT/manifests/ingress/kibana.yaml" | kubectl apply -f -
