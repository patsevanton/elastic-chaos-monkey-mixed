# Правила

- Зона только `ru-central1-a`. Изоляция (`isolate-zone.sh`/`restore-zone.sh`, `verify-ng-isolation-sg.sh`) и chaos-тесты (`chaos-run.sh`) выполняются исключительно для неё; скрипты отказываются работать с `b`/`d`. Манифесты chaos — с `ZONE=ru-central1-a`.
- После прогона хаоса — отчёт о влиянии всех аннотаций в `docs/chaos-report-<дата>.md`. Сбор данных: `RUN_FROM=<epoch начала прогона> ZONES=ru-central1-a ./scripts/collect-chaos-report.sh` (пишет `windows.tsv` и `analysis.tsv` в `.state/chaos-report-<дата>/` и **сам вызывает `scripts/make-chaos-report.sh`**, который детерминированно создаёт `docs/chaos-report-<дата>.md`). Представление отчёта: колонка «Дашборд → панель» — ссылка на дашборд Grafana за окно `pre + event` и перечень панелей, на которых видна метрика события (соответствие метрика → дашборд/панель задаёт карта `dashboard_panel` в `make-chaos-report.sh`); колонка «График» — ссылка на Grafana Explore (datasource `VictoriaMetrics`) с теми же метриками за то же окно, поэтому текст и график совпадают по построению; колонки «Вывод» и раздел «Ключевые находки» дописывает AI по `analysis.tsv` и графикам. Колонки «Эффект» в отчёте нет. Метрики на событие задаются картой `effect_metrics` в `make-chaos-report.sh` (pod-kill — `es_unassigned`/`es_health_red`/`es_queue`/`es_pending`; loss и delay — `bulk_p99_s`/`search_p99_s`; chaos-isolate — `bulk_err_pct`/`search_err_pct`/`goldpinger_unhealthy`/`cilium_max_s`; SG-isolate — ошибки и rps; SG-restore — связность и rps). Порог значимости не задан — по форме кривой.
- Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`. Power-off VM (`yc compute instance stop`) — не наш сценарий.
- `terraform apply` для переключения изоляции не применять: SG переключается CLI, иначе apply «чинит» эксперимент. Контракт — в [INFRASTRUCTURE.md](INFRASTRUCTURE.md).
- Стенд может быть собран, а может быть не собран. `terraform apply` идемпотентен: если стенд уже стоит — `No changes`, если нет — создаёт. Запускать нужно всегда.
- `./scripts/apply-eck.sh` (и манифест ECK) можно применять повторно: при неизменных шаблонах это no-op. Пересоздаёт ноды и PVC только при правке `nodeSets` (переименование/удаление nodeSet, уменьшение `count`, смена имени volume claim) или при удалении CR `Elasticsearch`.
- `./scripts/apply-cnpg.sh` можно применять повторно: при неизменном `manifests/cnpg/cluster.yaml` это no-op. Ставит оператор CNPG (chart 0.25.0) и кластер `pg-grafana` в namespace `vmks`; Grafana использует его как БД (аннотации, пользователи, сессии), поэтому скрипт надо прогнать до `helm -f vmks-values.yaml`. Namespace у CR `Cluster` неизменяем — при смене namespace пересоздавать CR; PVC при удалении CR пропадают (storageClass `Delete`).
- Перед первым прогоном на кластере — `./scripts/verify-ng-isolation-sg.sh "$(terraform output -raw zone_isolation_sg_id)" <zone> <node-group>` в контексте этого кластера, для каждой node group, которую будут изолировать. При `VERDICT: RECREATE` isolate/restore не использовать: остановиться, записать факт в отчёт и предложить варианты (вариант A — переписать isolate/restore на `yc compute instance update-network-interface`; вариант B — пропустить шаг изоляции, прогнав pod-kill/loss/delay). Автономно ни один вариант не применять.
- `disable-zones` не чаще раза в 2 минуты на NLB — при retry выдержать паузу.
- loadgen `ensureIndex` создаёт индекс `load` (1 primary / 2 replica, константы `indexShards`/`indexReplicas` в `loadgen/main.go`) бесконечным retry до готовности ES; при `resource_already_exists_exception` логирует в stderr и доводит реплики через `_settings`. После старта подов обязательно проверить логи (`kubectl --context app -n load logs -l app=loadgen`): при регулярных `ensureIndex: … retry` разобраться, почему ES/индекс недоступен, и не игнорировать.
- Ноды k8s без публичного IP. Исключение: API master обоих кластеров — внешний endpoint (`public_ip = true` в `k8s.tf`/`k8s-app.tf`), это осознанное решение для доступа с ноутбука, не нарушение правила.
- Стандартные Prometheus CRD (`monitoring.coreos.com/v1`) ставятся чартом `prometheus-community/prometheus-operator-crds` (32.0.1) в оба контекста **до** чартов, которые рендерят `ServiceMonitor` (Traefik, goldpinger, prometheus-elasticsearch-exporter). Сам prometheus-operator не ставится: `ServiceMonitor` собирает конвертер VM-оператора (в `victoria-metrics-k8s-stack` `victoria-metrics-operator.operator.disable_prometheus_converter: false`), преобразуя их в `VMServiceScrape`.

# Установка Prometheus CRD

```bash
helm --kube-context app upgrade --install prometheus-operator-crds \
    prometheus-community/prometheus-operator-crds \
    --namespace monitoring --create-namespace \
    --wait --version 32.0.1 --timeout 5m
helm --kube-context elastic upgrade --install prometheus-operator-crds \
    prometheus-community/prometheus-operator-crds \
    --namespace monitoring --create-namespace \
    --wait --version 32.0.1 --timeout 5m
```

# Установка VictoriaMetrics

Оба контекста, namespace `vmks`, chart 0.92.1. `app` — полный стек и Grafana (`vmks-values.yaml`). `elastic` — тот же chart без Grafana (`vmks-elastic-values.yaml`): CRD оператора для `VMAgent` и `VMServiceScrape`.

Перед `helm` в контексте `app` создать namespace, RBAC, дождаться токена (нужен Grafana как Chaos Mesh datasource) и поднять CNPG (Grafana хранит состояние в его PostgreSQL — до `helm` должны существовать оператор, кластер `pg-grafana` и секрет `pg-grafana-app`):

```bash
kubectl --context app create namespace vmks --dry-run=client -o yaml | kubectl --context app apply -f -
kubectl --context app apply -f manifests/chaos-mesh/rbac.yaml
kubectl --context app -n vmks wait --for=jsonpath='{.data.token}' secret/chaos-mesh-admin-token --timeout=60s
./scripts/apply-cnpg.sh
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

Traefik и goldpinger отдают `ServiceMonitor` через свои values (`metrics.prometheus.serviceMonitor.enabled`, `serviceMonitor.enabled`) — отдельные манифесты скрейпа не нужны. После `helm` в контексте `app` — internal NLB на `vminsert`:

```bash
NLB_SUBNET_ID="$(terraform output -raw nlb_subnet_id)" envsubst < manifests/vminsert/nlb.yaml \
  | kubectl --context app apply -f -
```

# Установка prometheus-elasticsearch-exporter

В контексте `elastic` (ES живёт там), helm-чарт `prometheus-community/prometheus-elasticsearch-exporter` **7.4.0** с `-f elasticsearch-exporter-values.yaml`: 3 реплики с spread по зонам, `es.uri` на `elastic-es-http.elastic.svc:9200`, `serviceMonitor.enabled: true`. Deployment в манифестах больше нет.

```bash
helm --kube-context elastic upgrade --install elasticsearch-exporter \
    prometheus-community/prometheus-elasticsearch-exporter \
    --namespace elastic \
    --wait --version 7.4.0 --timeout 5m \
    -f elasticsearch-exporter-values.yaml
```

Полный порядок установки стенда с нуля — в [docs/superpowers/plans/2026-09-30-elastic-chaos-total.md](docs/superpowers/plans/2026-09-30-elastic-chaos-total.md).
