#!/usr/bin/env bash
set -euo pipefail
ES="${ES_URL:-http://127.0.0.1:9200}"
INDEX="${INDEX:-osmlinestrings,osmmultilinestrings,osmpolygons}"
LOG="${ID_LOG:-$HOME/id-log/bulk-ids.txt}"
N="${1:-20}"
IFS=',' read -ra INDICES <<< "$INDEX"
if [ ! -f "$LOG" ]; then
  echo "нет id-лога $LOG" >&2
  exit 1
fi
IDS="$(shuf -n "$N" "$LOG")"
FOUND=0
MISS=0
while read -r ID; do
  [ -z "$ID" ] && continue
  OK=false
  for idx in "${INDICES[@]}"; do
    if [ "$(curl -sf "${ES}/${idx}/_doc/${ID}?_source=false" | jq -r '.found')" = "true" ]; then
      OK=true
      break
    fi
  done
  if [ "$OK" = "true" ]; then
    FOUND=$((FOUND + 1))
  else
    MISS=$((MISS + 1))
    echo "missing $ID"
  fi
done <<< "$IDS"
echo "sampled=${N} found=${FOUND} missing=${MISS}"
