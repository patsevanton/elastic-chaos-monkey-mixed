#!/usr/bin/env bash
set -euo pipefail
ES="${ES_URL:-http://127.0.0.1:9200}"
INDEX="${INDEX:-nyc_taxis}"
LOG="${ID_LOG:-$HOME/id-log/bulk-ids.txt}"
N="${1:-20}"
if [ ! -f "$LOG" ]; then
  echo "нет id-лога $LOG" >&2
  exit 1
fi
IDS="$(shuf -n "$N" "$LOG")"
FOUND=0
MISS=0
while read -r ID; do
  [ -z "$ID" ] && continue
  OK="$(curl -sf "${ES}/${INDEX}/_doc/${ID}?_source=false" | jq -r '.found')"
  if [ "$OK" = "true" ]; then
    FOUND=$((FOUND + 1))
  else
    MISS=$((MISS + 1))
    echo "missing $ID"
  fi
done <<< "$IDS"
echo "sampled=${N} found=${FOUND} missing=${MISS}"
