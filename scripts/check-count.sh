#!/usr/bin/env bash
set -euo pipefail
ES="${ES_URL:-http://127.0.0.1:9200}"
INDEX="${INDEX:-nyc_taxis}"
ACCEPTED="${1:-}"
COUNT="$(curl -sf "${ES}/${INDEX}/_count" | jq '.count')"
echo "index=${INDEX} _count=${COUNT} accepted_bulk=${ACCEPTED:-unset}"
if [ -n "$ACCEPTED" ]; then
  echo "delta=$((COUNT - ACCEPTED))"
fi
