# Правила

- Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`. Power-off VM (`yc compute instance stop`) — не наш сценарий.
- `terraform apply` для переключения изоляции не применять: SG переключается CLI, иначе apply «чинит» эксперимент. Контракт — в [INFRASTRUCTURE.md](INFRASTRUCTURE.md).
- Стенд может быть собран, а может быть не собран. `terraform apply` идемпотентен: если стенд уже стоит — `No changes`, если нет — создаёт. Запускать нужно всегда.
- `./scripts/apply-eck.sh` (и манифест ECK) можно применять повторно: при неизменных шаблонах это no-op. Пересоздаёт ноды и PVC только при правке `nodeSets` (переименование/удаление nodeSet, уменьшение `count`, смена имени volume claim) или при удалении CR `Elasticsearch`.
- Перед первым прогоном на кластере — `./scripts/verify-ng-isolation-sg.sh "$(terraform output -raw zone_isolation_sg_id)" <zone> <node-group>` в контексте этого кластера, для каждой node group, которую будут изолировать. При `VERDICT: RECREATE` isolate/restore не использовать: остановиться, записать факт в отчёт и предложить варианты (вариант A — переписать isolate/restore на `yc compute instance update-network-interface`; вариант B — пропустить шаг изоляции, прогнав pod-kill/loss/delay). Автономно ни один вариант не применять.
- `disable-zones` не чаще раза в 2 минуты на NLB — при retry выдержать паузу.
- loadgen `ensureIndex` создаёт индекс `load` (1 primary / 2 replica, константы `indexShards`/`indexReplicas` в `loadgen/main.go`) бесконечным retry до готовности ES; при `resource_already_exists_exception` логирует в stderr и доводит реплики через `_settings`. После старта подов обязательно проверить логи (`kubectl --context app -n load logs -l app=loadgen`): при регулярных `ensureIndex: … retry` разобраться, почему ES/индекс недоступен, и не игнорировать.
- Ноды k8s без публичного IP. Исключение: API master обоих кластеров — внешний endpoint (`public_ip = true` в `k8s.tf`/`k8s-app.tf`), это осознанное решение для доступа с ноутбука, не нарушение правила.

# Установка VictoriaMetrics

Оба контекста, namespace `vmks`, chart 0.92.1. `app` — полный стек и Grafana (`vmks-values.yaml`). `elastic` — тот же chart без Grafana (`vmks-elastic-values.yaml`): CRD оператора для `VMAgent` и `VMServiceScrape`.

Перед `helm` в контексте `app` создать namespace, RBAC и дождаться токена (нужен Grafana как Chaos Mesh datasource):

```bash
kubectl --context app create namespace vmks --dry-run=client -o yaml | kubectl --context app apply -f -
kubectl --context app apply -f manifests/chaos-mesh/rbac.yaml
kubectl --context app -n vmks wait --for=jsonpath='{.data.token}' secret/chaos-mesh-admin-token --timeout=60s
```

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

После `helm` в контексте `app` — scrape Traefik и internal NLB на `vminsert`:

```bash
kubectl --context app apply -f manifests/exporter/traefik-scrape.yaml
NLB_SUBNET_ID="$(terraform output -raw nlb_subnet_id)" envsubst < manifests/vminsert/nlb.yaml \
  | kubectl --context app apply -f -
```

Полный порядок установки стенда с нуля — в [docs/superpowers/plans/2026-09-30-elastic-chaos-total.md](docs/superpowers/plans/2026-09-30-elastic-chaos-total.md).
