#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZONE="ru-central1-b"
NG_NAME="elastic-chaos-b"
STATE_FILE="$ROOT/.state/zone-b-isolate.env"

mkdir -p "$ROOT/.state"

NODE="$(kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o jsonpath='{.items[0].metadata.name}')"
INSTANCE_ID="$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}')"
INSTANCE_ID="${INSTANCE_ID##*/}"

NG_JSON="$(yc managed-kubernetes node-group get "$NG_NAME" --format json)"
CURRENT_SG_IDS="$(jq -r '.node_template.network_interface_specs[0].security_group_ids // [] | join(",")' <<<"$NG_JSON")"
SUBNET_IDS="$(jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")' <<<"$NG_JSON")"

ES_IP="$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

nlb_id_by_ip() {
  yc load-balancer network-load-balancer list --format json \
    | jq -r --arg ip "$1" '[.[] | select(any(.listeners[]?; .address == $ip))][0].id // empty'
}

NLB_ES_ID="$(nlb_id_by_ip "$ES_IP")"
NLB_TRAEFIK_ID="$(nlb_id_by_ip "$TRAEFIK_IP")"

if [ -z "$NLB_ES_ID" ] || [ -z "$NLB_TRAEFIK_ID" ]; then
  echo "не нашли NLB: es_ip=${ES_IP} nlb_es=${NLB_ES_ID:-<нет>} traefik_ip=${TRAEFIK_IP} nlb_traefik=${NLB_TRAEFIK_ID:-<нет>}" >&2
  echo "список: yc load-balancer network-load-balancer list" >&2
  exit 1
fi

SG_ID="$(terraform output -raw zone_isolation_sg_id)"

cat > "$STATE_FILE" <<EOF
ZONE=$ZONE
NG_NAME=$NG_NAME
INSTANCE_ID=$INSTANCE_ID
SG_IDS=$CURRENT_SG_IDS
NLB_ES_ID=$NLB_ES_ID
NLB_TRAEFIK_ID=$NLB_TRAEFIK_ID
EOF

echo "state: $STATE_FILE"
echo "isolate instance=$INSTANCE_ID ng=$NG_NAME sg=$SG_ID nlb_es=$NLB_ES_ID nlb_traefik=$NLB_TRAEFIK_ID"

yc managed-kubernetes node-group update "$NG_NAME" --network-interface "subnets=${SUBNET_IDS},security-group-ids=[${SG_ID}]"
yc load-balancer network-load-balancer disable-zones --id "$NLB_ES_ID" --zones "$ZONE"
yc load-balancer network-load-balancer disable-zones --id "$NLB_TRAEFIK_ID" --zones "$ZONE"

echo "zone $ZONE isolated: sg=$SG_ID on $NG_NAME, disable-zones on $NLB_ES_ID и $NLB_TRAEFIK_ID"
