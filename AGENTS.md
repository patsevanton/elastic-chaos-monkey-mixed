# Правила

- Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`. Power-off VM (`yc compute instance stop`) — не наш сценарий.
- `terraform apply` для переключения изоляции не применять: SG переключается CLI, иначе apply «чинит» эксперимент. Контракт — в [INFRASTRUCTURE.md](INFRASTRUCTURE.md).
- Перед первым прогоном на кластере — `./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)" <zone> <node-group>` в контексте этого кластера, для каждой node group, которую будут изолировать. При `VERDICT: RECREATE` isolate/restore не использовать, переписать на `yc compute instance update-network-interface`.
- `disable-zones` не чаще раза в 2 минуты на NLB — при retry выдержать паузу.
- `./scripts/check-zone-b-down.sh` — ручная проверка изоляции зоны `ru-central1-b`. Не удалять.

# Установка VictoriaMetrics

Оба контекста, namespace `vmks`, chart 0.92.1. `app` — полный стек и Grafana (`vmks-values.yaml`). `elastic` — тот же chart без Grafana (`vmks-elastic-values.yaml`): CRD оператора для `VMAgent` и `VMServiceScrape`.

```bash
helm --kube-context app upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-values.yaml
helm --kube-context elastic upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-elastic-values.yaml
```
