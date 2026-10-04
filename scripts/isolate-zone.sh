#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZONE="${1:?usage: isolate-zone.sh ru-central1-a}"
case "$ZONE" in
  ru-central1-a) SUFFIX=a ;;
  *) echo "изолируем только ru-central1-a, а не $ZONE" >&2; exit 1 ;;
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
TRAEFIK_APP_IP="$(kubectl --context app -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
TRAEFIK_APP_PUBLIC_IP="$(kubectl --context app -n traefik get svc traefik-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
NLB_TRAEFIK_ID="$(nlb_id_by_ip "$TRAEFIK_IP")"
NLB_VMINSERT_ID="$(nlb_id_by_ip "$VMINSERT_IP")"
NLB_APP_TRAEFIK_ID="$(nlb_id_by_ip "$TRAEFIK_APP_IP")"
NLB_APP_PUBLIC_ID="$(nlb_id_by_ip "$TRAEFIK_APP_PUBLIC_IP")"
if [ -z "$NLB_TRAEFIK_ID" ] || [ -z "$NLB_VMINSERT_ID" ] \
   || [ -z "$NLB_APP_TRAEFIK_ID" ] || [ -z "$NLB_APP_PUBLIC_ID" ]; then
  echo "не нашли NLB traefik=$NLB_TRAEFIK_ID vminsert=$NLB_VMINSERT_ID app-traefik=$NLB_APP_TRAEFIK_ID app-public=$NLB_APP_PUBLIC_ID" >&2
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
NLB_APP_TRAEFIK_ID=$NLB_APP_TRAEFIK_ID
NLB_APP_PUBLIC_ID=$NLB_APP_PUBLIC_ID
EOF

apply_isolation_sg() {
  local ng="$1" subnets="$2" sg="$3"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: isolate SG $ng start" sg isolate "$ZONE" "$ng" start
  yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets},security-group-ids=[${sg}]"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: isolate SG $ng end" sg isolate "$ZONE" "$ng" end
}

# disable-zones на все NLB до применения SG: иначе внешний NLB кластера app
# продолжает слать трафик в зону, которую вот-вот изолируем, и запросы к
# Grafana по публичному IP виснут (пустой SG дропает пакеты). Правило
# «не чаще раза в 2 минуты» действует на один NLB, поэтому вызовы для разных
# NLB идут параллельно.
disable_zone() {
  local id="$1"
  yc load-balancer network-load-balancer disable-zones --id "$id" --zones "$ZONE"
}
echo "isolate $ZONE sg=$SG_ID ng=$MASTER_NG,$DATA_NG,$APP_NG nlb=$NLB_TRAEFIK_ID,$NLB_VMINSERT_ID,$NLB_APP_TRAEFIK_ID,$NLB_APP_PUBLIC_ID"
nlb_pids=()
disable_zone "$NLB_TRAEFIK_ID" & nlb_pids+=("$!")
disable_zone "$NLB_VMINSERT_ID" & nlb_pids+=("$!")
disable_zone "$NLB_APP_TRAEFIK_ID" & nlb_pids+=("$!")
disable_zone "$NLB_APP_PUBLIC_ID" & nlb_pids+=("$!")
nlb_fail=0
for p in "${nlb_pids[@]}"; do
  if ! wait "$p"; then nlb_fail=1; fi
done
if [ "$nlb_fail" -ne 0 ]; then
  echo "disable-zones на одном или нескольких NLB не удался" >&2
  exit 1
fi

pids=()
apply_isolation_sg "$MASTER_NG" "$MASTER_SUBNETS" "$SG_ID" & pids+=("$!")
apply_isolation_sg "$DATA_NG" "$DATA_SUBNETS" "$SG_ID" & pids+=("$!")
apply_isolation_sg "$APP_NG" "$APP_SUBNETS" "$SG_ID" & pids+=("$!")
fail=0
for p in "${pids[@]}"; do
  if ! wait "$p"; then fail=1; fi
done
if [ "$fail" -ne 0 ]; then
  echo "один или несколько node-group update не удались" >&2
  exit 1
fi
echo "zone $ZONE isolated"
