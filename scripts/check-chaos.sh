#!/usr/bin/env bash
set -euo pipefail
KIND="${1:?podchaos|networkchaos}"
NAME="${2:?name}"
# Chaos CR живут в двух кластерах: ES-хаос — ns elastic кластера elastic,
# loadgen-хаос — ns load кластера app. Определяем по имени CR, можно
# переопределить третьим (context) и четвёртым (namespace) аргументами.
case "$NAME" in
  loadgen-*) DEFAULT_CONTEXT=app; DEFAULT_NAMESPACE=load ;;
  *)         DEFAULT_CONTEXT=elastic; DEFAULT_NAMESPACE=elastic ;;
esac
CONTEXT="${3:-$DEFAULT_CONTEXT}"
NAMESPACE="${4:-$DEFAULT_NAMESPACE}"
PHASE="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get "$KIND" "$NAME" -o jsonpath='{.status.experiment.containerRecords[0].phase}')"
ID="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get "$KIND" "$NAME" -o jsonpath='{.status.experiment.containerRecords[0].id}')"
echo "chaos ${KIND}/${NAME} ctx=${CONTEXT} ns=${NAMESPACE} phase=${PHASE} target=${ID}"
test "$PHASE" = "Injected"
