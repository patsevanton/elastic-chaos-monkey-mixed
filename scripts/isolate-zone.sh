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

SG_ID="$(terraform output -raw zone_isolation_sg_id)"

cat > "$STATE_FILE" <<EOF
ZONE=$ZONE
ELASTIC_MASTER_NG=$MASTER_NG
ELASTIC_DATA_NG=$DATA_NG
APP_NG=$APP_NG
ELASTIC_MASTER_SG=$MASTER_SG
ELASTIC_DATA_SG=$DATA_SG
APP_SG=$APP_SG
EOF

apply_isolation_sg() {
  local ng="$1" subnets="$2" sg="$3"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: isolate SG $ng start" sg isolate "$ZONE" "$ng" start
  yc managed-kubernetes node-group update "$ng" --network-interface "subnets=${subnets},security-group-ids=[${sg}]"
  "$ROOT/scripts/annotate-grafana.sh" "zone $ZONE: isolate SG $ng end" sg isolate "$ZONE" "$ng" end
}

echo "isolate $ZONE sg=$SG_ID ng=$MASTER_NG,$DATA_NG,$APP_NG"
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
