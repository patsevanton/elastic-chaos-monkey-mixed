#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZONE="ru-central1-b"
NODE="$(kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o jsonpath='{.items[0].metadata.name}')"
READY="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
ID="$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}')"
ID="${ID##*/}"
IP="$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
VM="$(yc compute instance get "$ID" --format json | jq -r '.status')"
echo "node=${NODE} ready=${READY} vm=${ID} vm_status=${VM} ip=${IP}"

case "$READY" in
  False|Unknown) ;;
  *) echo "node Ready=${READY}, ожидался False или Unknown" >&2; exit 1 ;;
esac

if [ "$VM" != "RUNNING" ]; then
  echo "vm_status=${VM}, ожидался RUNNING: изоляция SG, а не power-off" >&2
  exit 1
fi

if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
  echo "node ip ${IP} answers ping" >&2
  exit 1
fi

ES_IP="$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

nlb_id_by_ip() {
  yc load-balancer network-load-balancer list --format json \
    | jq -r --arg ip "$1" '[.[] | select(any(.listeners[]?; .address == $ip))][0].id // empty'
}

check_nlb() {
  local name="$1" nlb_id="$2"
  if [ -z "$nlb_id" ]; then
    echo "${name}: NLB не найден" >&2
    exit 1
  fi

  local nlb lock
  nlb="$(yc load-balancer network-load-balancer get "$nlb_id" --format json)"
  lock="$(jq -r --arg z "$ZONE" '
    (if type == "array" then .[0] else . end)
    | (.disable_zone_statuses // .disableZoneStatuses // [])
    | map(.zone_id // .zoneId)
    | if index($z) == null then "absent" else "present" end
  ' <<<"$nlb")"
  if [ "$lock" != "present" ]; then
    echo "${name} ${nlb_id}: в disable_zone_statuses нет ${ZONE}" >&2
    exit 1
  fi

  local shifted
  shifted="$(yc load-balancer network-load-balancer target-states "$nlb_id" --format json | jq -r --arg ip "$IP" '
    (if type == "array" then . else (.target_states // .targetStates // []) end) as $t
    | ([ $t[] | select(.address == $ip) ]) as $m
    | if ($m | length) == 0 then "missing"
      elif ([ $m[] | select((.zone_shifted // .zoneShifted // false) != true) ] | length) > 0 then "not_shifted"
      else "ok" end
  ')"
  if [ "$shifted" != "ok" ]; then
    echo "${name} ${nlb_id}: target ${IP} — ${shifted}, ожидался zone_shifted=true" >&2
    exit 1
  fi

  echo "${name} ${nlb_id}: ${ZONE} in disable_zone_statuses, target ${IP} zone_shifted"
}

check_nlb es "$(nlb_id_by_ip "$ES_IP")"
check_nlb traefik "$(nlb_id_by_ip "$TRAEFIK_IP")"

echo "zone b down: node not Ready, VM RUNNING, ${IP} unreachable, NLB disable-zones ok"
