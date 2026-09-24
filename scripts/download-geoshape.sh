#!/usr/bin/env bash
set -euo pipefail
DIR="${1:-geoshape}"
BASE="https://storage.yandexcloud.net/download-resources-for-apatsev"
mkdir -p "$DIR"
cd "$DIR"
for f in linestrings.json.bz2; do
  # polygons.json.bz2 — osmpolygons, не используется
  # multilinestrings.json.bz2 — удалён
  curl -fL --retry 5 --retry-delay 5 -o "$f" "${BASE}/${f}"
done
