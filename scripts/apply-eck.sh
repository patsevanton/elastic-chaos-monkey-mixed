#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SUBNET_ID="$(terraform output -raw nlb_subnet_id)"
ES_NLB_IP="$(terraform output -raw es_nlb_ip)"
INGRESS_IP="$(terraform output -raw traefik_ip)"
kubectl create namespace elastic --dry-run=client -o yaml | kubectl apply -f -
sed -e "s/NLB_SUBNET_ID/${SUBNET_ID}/" -e "s/ES_NLB_IP/${ES_NLB_IP}/" "$ROOT/manifests/eck/elasticsearch.yaml" | kubectl apply -f -
kubectl apply -f "$ROOT/manifests/eck/kibana.yaml"
sed "s/INGRESS_IP/${INGRESS_IP}/" "$ROOT/manifests/ingress/kibana.yaml" | kubectl apply -f -
