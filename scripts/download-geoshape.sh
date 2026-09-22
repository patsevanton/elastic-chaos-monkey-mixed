#!/usr/bin/env bash
set -euo pipefail
DIR="${1:-geoshape}"
BASE="https://rally-tracks.elastic.co/geoshape"
mkdir -p "$DIR"
cd "$DIR"
for f in linestrings.json.bz2 multilinestrings.json.bz2 polygons.json.bz2; do
  curl -fL --retry 5 --retry-delay 5 -o "$f" "${BASE}/${f}"
done
