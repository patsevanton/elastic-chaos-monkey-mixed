#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEXT="${1:?usage: annotate-grafana.sh <text> [tag...]}"
shift
TAGS_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

GRAFANA_URL="${GRAFANA_URL:-$(terraform output -raw grafana_url)}"
GRAFANA_USER=admin
GRAFANA_PASSWORD="$(kubectl --context app -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d)}"

PAYLOAD="$(jq -n \
  --arg text "$TEXT" \
  --argjson tags "$TAGS_JSON" \
  --argjson time "$(( $(date +%s) * 1000 ))" \
  '{text: $text, tags: $tags, time: $time}')"

# curl без --max-time мог висеть бесконечно, когда зона изолирована и
# публичный NLB app ещё шлёт трафик в мёртвую зону; при set -e это намертво
# блокировало isolate/restore. Ограничиваем время и повторяем несколько раз.
attempt=1
while :; do
  if curl -fsS --max-time 10 -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -X POST "${GRAFANA_URL}/api/annotations" -d "$PAYLOAD" >/dev/null; then
    break
  fi
  if [ "$attempt" -ge 3 ]; then
    echo "annotate: не удалось за 3 попыток ($TEXT)" >&2
    exit 1
  fi
  echo "annotate: попытка $attempt не удалась, повтор через 2s" >&2
  attempt=$((attempt + 1))
  sleep 2
done
echo "annotation: $TEXT"
