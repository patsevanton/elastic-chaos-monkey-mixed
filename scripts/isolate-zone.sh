#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZONE="${1:?usage: isolate-zone.sh ru-central1-a|b|d}"
case "$ZONE" in
  ru-central1-a) SUFFIX=a ;;
  ru-central1-b) SUFFIX=b ;;
  ru-central1-d) SUFFIX=d ;;
  *) echo "зона $ZONE не из a/b/d" >&2; exit 1 ;;
esac
STATE_FILE="$ROOT/.state/zone-isolate.env"
mkdir -p "$ROOT/.state"
if [ -f "$STATE_FILE" ]; then
  echo "уже есть $STATE_FILE" >&2
  exit 1
fi

ng_json() { yc managed-kubernetes node-group get "$1" --format json; }
sg_of() { jq -r '.node_template.network_interface_specs[0].security_group_ids // [] | join(",")' <<<"$1"; }
subnets_of() { jq -r '.node_template.network_interface_specs[0].subnet_ids // [] | join(",")' <<<"$1"; }

MASTER_NG="elastic-master-${SUFFIX}"
DATA_NG="elastic-data-${SUFFIX}"
APP_NG="app-${SUFFIX}"
MASTER_JSON="$(ng_json "$MASTER_NG")"
DATA_JSON="$(ng_json "$DATA_NG")"
APP_JSON="$(ng_json "$APP_NG")"
MASTER_SG="$(sg_of "$MASTER_JSON")"
DATA_SG="$(sg_of "$DATA_JSON")"
APP_SG="$(sg_of "$APP_JSON")"
MASTER_SUBNETS="$(subnets_of "$MASTER_JSON")"
DATA_SUBNETS="$(subnets_of "$DATA_JSON")"
APP_SUBNETS="$(subnets_of "$APP_JSON")"

nlb_id_by_ip() {
  yc load-balancer network-load-balancer list --format json \
    | jq -r --arg ip "$1" '[.[] | select(any(.listeners[]?; .address == $ip))][0].id // empty'
}
TRAEFIK_IP="$(kubectl --context elastic -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
VMINSERT_IP="$(kubectl --context app -n vmks get svc vminsert-nlb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
NLB_TRAEFIK_ID="$(nlb_id_by_ip "$TRAEFIK_IP")"
NLB_VMINSERT_ID="$(nlb_id_by_ip "$VMINSERT_IP")"
if [ -z "$NLB_TRAEFIK_ID" ] || [ -z "$NLB_VMINSERT_ID" ]; then
  echo "не нашли NLB traefik=$NLB_TRAEFIK_ID vminsert=$NLB_VMINSERT_ID" >&2
  exit 1
fi
SG_ID="$(terraform output -raw zone_isolation_sg_id)"

cat > "$STATE_FILE" <<EOF
ZONE=$ZONE
ELASTIC_MASTER_NG=$MASTER_NG
ELASTIC_DATA_NG=$DATA_NG
APP_NG=$APP_NG
ELASTIC_MASTER_SG=$MASTER_SG
ELASTIC_DATA_SG=$DATA_SG
APP_SG=$APP_SG
NLB_TRAEFIK_ID=$NLB_TRAEFIK_ID
NLB_VMINSERT_ID=$NLB_VMINSERT_ID
EOF

echo "isolate $ZONE sg=$SG_ID ng=$MASTER_NG,$DATA_NG,$APP_NG"
yc managed-kubernetes node-group update "$MASTER_NG" --network-interface "subnets=${MASTER_SUBNETS},security-group-ids=[${SG_ID}]"
yc managed-kubernetes node-group update "$DATA_NG" --network-interface "subnets=${DATA_SUBNETS},security-group-ids=[${SG_ID}]"
yc managed-kubernetes node-group update "$APP_NG" --network-interface "subnets=${APP_SUBNETS},security-group-ids=[${SG_ID}]"
yc load-balancer network-load-balancer disable-zones --id "$NLB_TRAEFIK_ID" --zones "$ZONE"
sleep 120
yc load-balancer network-load-balancer disable-zones --id "$NLB_VMINSERT_ID" --zones "$ZONE"
echo "zone $ZONE isolated"
