# Отказоустойчивость Elasticsearch: два кластера

Кластер `elastic` держит Elasticsearch. Кластер `app` пишет и читает его через Traefik. Стенд ломает по очереди зоны `ru-central1-a`, `b`, `d`: pod-kill, network loss 30%, network delay 500 мс, затем сетевая изоляция зоны. Оба кластера в одном шаге, одновременно. VM не выключается.

Критерии: search жив, index жив, нет потери документов, которые bulk принял. Порога нет: печатаем процент ошибок приложения.

Путь: под `loadgen` → internal NLB Traefik кластера `elastic` (`10.0.1.33`) → Elasticsearch ClusterIP `:9200`. Прямого NLB Elasticsearch нет. Ingress-nginx нет.

Документ временный, 2 КБ: `id`, `ts`, `zone`, `body`. Состав полей будет переспрошен. Индекс `load`: 1 primary, 2 replica.

## Стенд

| Компонент | Куда |
|---|---|
| Elasticsearch 9.5.4 master ×3 + data ×6 | кластер `elastic`, зоны `a`/`b`/`d`, data по 2 на зону; data PVC **50 ГиБ** `yc-network-ssd`, heap 3 ГиБ; master без PVC, heap 1 ГиБ |
| Kibana 9.5.4 ×3 | публичный NLB Traefik, `kibana.<IP>.sslip.io` |
| loadgen ×3 | кластер `app`, spread по зонам |
| vmks 0.92.1 | `app` и `elastic`, namespace `vmks` |
| Traefik 41.6.0 ×3 | оба кластера: internal NLB и публичный NLB |
| Chaos Mesh 2.8.4 | оба кластера |

Ноды без публичного IP, HDD, preemptible. `elastic`: master 2 vCPU / 4 ГБ, data 8 vCPU / 16 ГБ. `app`: 4 vCPU / 8 ГБ. SA `elastic-chaos-monkey`. Kubernetes **1.33**.

Инфра: [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

## Установка

```bash
export TF_VAR_folder_id=<folder id>
terraform init && terraform apply
eval "$(terraform output -raw elastic_credentials_command)"
eval "$(terraform output -raw app_credentials_command)"
```

Traefik в оба контекста, chart 41.6.0 (OCI, `helm repo add` не нужен): `-f traefik-elastic-values.yaml` в контексте `elastic`, `-f traefik-app-values.yaml` в контексте `app`.

```bash
helm --kube-context elastic upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
  --namespace traefik --create-namespace --version 41.6.0 \
  -f traefik-elastic-values.yaml
helm --kube-context app upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
  --namespace traefik --create-namespace --version 41.6.0 \
  -f traefik-app-values.yaml
```

vmks в оба контекста, chart 0.92.1, namespace `vmks`. Grafana и `chaos-mesh-admin-token` только в `app`. В `elastic` — тот же chart, без Grafana: CRD оператора нужны `VMAgent` и `VMServiceScrape`.

```bash
kubectl --context app create namespace vmks --dry-run=client -o yaml | kubectl --context app apply -f -
kubectl --context app apply -f manifests/chaos-mesh/rbac.yaml
kubectl --context app -n vmks wait --for=jsonpath='{.data.token}' secret/chaos-mesh-admin-token --timeout=60s
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
kubectl --context app apply -f manifests/exporter/traefik-scrape.yaml
NLB_SUBNET_ID="$(terraform output -raw nlb_subnet_id)" envsubst < manifests/vminsert/nlb.yaml \
  | kubectl --context app apply -f -
```

ECK и exporter только в `elastic`:

```bash
helm repo add elastic https://helm.elastic.co
helm --kube-context elastic upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --create-namespace --version 3.5.0 --set replicaCount=3
./scripts/apply-eck.sh
kubectl --context elastic apply -f manifests/exporter/elasticsearch-exporter.yaml
kubectl --context elastic apply -f manifests/vmagent/vmagent.yaml
```

Chaos Mesh 2.8.4 в оба контекста: `-f chaos-mesh-elastic-values.yaml` и `-f chaos-mesh-app-values.yaml`.

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm --kube-context elastic upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace --version 2.8.4 \
  -f chaos-mesh-elastic-values.yaml
helm --kube-context app upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace --version 2.8.4 \
  -f chaos-mesh-app-values.yaml
kubectl --context app apply -f manifests/exporter/chaos-mesh-scrape.yaml
```

loadgen в `app`, образ `ghcr.io/patsevanton/elastic-chaos-monkey-mixed` (собирается workflow `.github/workflows/docker.yml` при push в `main`, публикуется в GHCR; тег фиксирован в `loadgen/chart/values.yaml`):

```bash
helm --kube-context app upgrade --install loadgen loadgen/chart \
  --namespace load --create-namespace
```

## Прогон

Перед первым разом на каждой node group, которую будут изолировать:

```bash
kubectl config use-context elastic
./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)" ru-central1-a elastic-master-a
./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)" ru-central1-a elastic-data-a
```

То же для `elastic-master-b`, `elastic-master-d`, `elastic-data-b`, `elastic-data-d` и, в контексте `app`, для `app-a`, `app-b`, `app-d`. `VERDICT: RECREATE` — isolate/restore не использовать.

```bash
./scripts/chaos-run.sh
```

Порядок зон: `a`, `b`, `d`. На зону: 10 минут pod-kill (каждые 30 с), 10 минут покой, 10 минут loss 30% (`direction: both`), покой, 10 минут delay 500 мс, покой, 10 минут изоляция, restore, покой. После каждого шага скрипт печатает счётчики и `_count`. Цифры результатов — плейсхолдеры до прогона.

| Зона | Шаг | bulk err % | search err % | _count |
|---|---|---|---|---|
| a | pod-kill | — | — | — |
| a | loss | — | — | — |
| a | delay | — | — | — |
| a | isolate | — | — | — |
| b | pod-kill | — | — | — |
| b | loss | — | — | — |
| b | delay | — | — | — |
| b | isolate | — | — | — |
| d | pod-kill | — | — | — |
| d | loss | — | — | — |
| d | delay | — | — | — |
| d | isolate | — | — | — |

Стоп: Ctrl-C в `chaos-run.sh` снимает Chaos CR и вызывает restore, если зона изолирована. Вручную: остановить loadgen, `./scripts/restore-zone.sh`, удалить Chaos CR. Не `terraform apply` и не power-off.
