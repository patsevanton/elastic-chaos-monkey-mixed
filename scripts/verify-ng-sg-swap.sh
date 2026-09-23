#!/usr/bin/env bash
set -euo pipefail
ZONE="ru-central1-b"
NG_NAME="elastic-chaos-b"
SG_ID="${1:?usage: verify-ng-sg-swap.sh <isolation-sg-id>}"

snapshot() {
  kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o json | jq -r '
    .items[]
    | [ .metadata.name, .metadata.uid, (.spec.providerID | split("/") | last) ] | @tsv
  ' | sort | while IFS=$'\t' read -r name uid vmid; do
    c_at="$(yc compute instance get "$vmid" --format json | jq -r '.created_at')"
    printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$vmid" "$c_at"
  done
}

CURRENT_SG_IDS="$(yc managed-kubernetes node-group get "$NG_NAME" --format json \
  | jq -r '.node_template.network_interface_specs[0].security_group_ids // [] | join(",")')"

restore() {
  echo "restore ${NG_NAME} sg=[${CURRENT_SG_IDS}]"
  yc managed-kubernetes node-group update "$NG_NAME" --network-interface "security-group-ids=[${CURRENT_SG_IDS}]"
}
trap restore EXIT

BEFORE="$(snapshot)"
echo "before:"
echo "$BEFORE"

echo "apply sg ${SG_ID} on ${NG_NAME}"
yc managed-kubernetes node-group update "$NG_NAME" --network-interface "security-group-ids=[${SG_ID}]"

AFTER=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  sleep 10
  AFTER="$(snapshot)"
  if [ "$AFTER" != "$BEFORE" ]; then
    break
  fi
done

echo "after:"
echo "$AFTER"

if [ "$AFTER" = "$BEFORE" ]; then
  echo "VERDICT: HOT-SWAP — узел не пересоздан, SG сменён на живой VM."
  echo "Используем node-group update в isolate-zone-b.sh."
else
  echo "VERDICT: RECREATE — узел пересоздан (name/uid/instance_id/created_at изменились)."
  echo "Node-group update НЕ подходит для network partition — нужен вариант C:"
  echo "  yc compute instance update-network-interface --network-interface-index 0 --security-group-id <sg>"
  echo "И переписать isolate-zone-b.sh / restore-zone-b.sh на работу с VM."
fi
