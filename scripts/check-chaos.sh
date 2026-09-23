#!/usr/bin/env bash
set -euo pipefail
KIND="${1:?podchaos|networkchaos}"
NAME="${2:?name}"
PHASE="$(kubectl -n elastic get "$KIND" "$NAME" -o jsonpath='{.status.experiment.containerRecords[0].phase}')"
ID="$(kubectl -n elastic get "$KIND" "$NAME" -o jsonpath='{.status.experiment.containerRecords[0].id}')"
echo "chaos ${KIND}/${NAME} phase=${PHASE} target=${ID}"
test "$PHASE" = "Injected"
