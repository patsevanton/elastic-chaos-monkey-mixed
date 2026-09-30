#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEXT="${1:?usage: annotate-grafana.sh <text> [tag...]}"
shift || true
TAGS_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

GRAFANA_URL="${GRAFANA_URL:-$(terraform output -raw grafana_url)}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
if [ -z "${GRAFANA_PASSWORD:-}" ]; then
  GRAFANA_PASSWORD="$(kubectl --context app -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
fi

PAYLOAD="$(jq -n \
  --arg text "$TEXT" \
  --argjson tags "$TAGS_JSON" \
  --argjson time "$(( $(date +%s) * 1000 ))" \
  '{text: $text, tags: $tags, time: $time}')"

curl -fsS -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -X POST "${GRAFANA_URL}/api/annotations" -d "$PAYLOAD" >/dev/null
echo "annotation: $TEXT"
