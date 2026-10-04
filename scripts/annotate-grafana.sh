#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEXT="${1:?usage: annotate-grafana.sh <text> [tag...]}"
shift
TAGS_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

GRAFANA_URL="${GRAFANA_URL:-$(terraform output -raw grafana_url)}"
GRAFANA_USER=admin
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(kubectl --context app -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d)}"
CURL_MAX_TIME="${GRAFANA_CURL_MAX_TIME:-10}"
CURL_RETRIES="${GRAFANA_CURL_RETRIES:-3}"
CURL_RETRY_DELAY="${GRAFANA_CURL_RETRY_DELAY:-2}"

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
  if curl -fsS --max-time "$CURL_MAX_TIME" -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -X POST "${GRAFANA_URL}/api/annotations" -d "$PAYLOAD" >/dev/null; then
    break
  fi
  if [ "$attempt" -ge "$CURL_RETRIES" ]; then
    echo "annotate: не удалось за $CURL_RETRIES попыток ($TEXT)" >&2
    exit 1
  fi
  echo "annotate: попытка $attempt не удалась, повтор через ${CURL_RETRY_DELAY}s" >&2
  attempt=$((attempt + 1))
  sleep "$CURL_RETRY_DELAY"
done
echo "annotation: $TEXT"
