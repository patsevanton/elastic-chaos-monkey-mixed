# Отказоустойчивость Elasticsearch: два кластера

Кластер `elastic` держит Elasticsearch. Кластер `app` пишет и читает его через Traefik. Стенд ломает по очереди зоны `ru-central1-a`, `b`, `d`: pod-kill, network loss 30%, network delay 500 мс, затем сетевая изоляция зоны. Оба кластера в одном шаге, одновременно. VM не выключается.

Критерии: search жив, index жив, нет потери документов, которые bulk принял. Порога нет: печатаем процент ошибок приложения.

Путь: под `loadgen` → internal NLB Traefik кластера `elastic` (`10.0.1.33`) → Elasticsearch ClusterIP `:9200`. Прямого NLB Elasticsearch нет. Ingress-nginx нет.

Документ временный, 2 КБ: `id`, `ts`, `zone`, `body`. Состав полей будет переспрошен. Индекс `load`: 1 primary, 2 replica.

## Стенд

| Компонент | Куда |
|---|---|
| Elasticsearch 9.5.4 mixed ×3 | кластер `elastic`, зоны `a`/`b`/`d`, PVC **50 ГиБ** `yc-network-ssd`, heap 3 ГиБ |
| Kibana 9.5.4 ×3 | Traefik `elastic`, без basic auth |
| loadgen ×3 | кластер `app`, spread по зонам |
| vmks 0.92.1 | только `app`, namespace `vmks` |
| Traefik 41.6.0 ×3 | оба кластера, internal NLB |
| Chaos Mesh 2.8.4 | оба кластера |

Ноды без публичного IP, HDD, preemptible. `elastic`: 8 vCPU / 16 ГБ. `app`: 2 vCPU / 4 ГБ. SA `elastic-chaos-monkey`. Kubernetes **1.33**.

Инфра: [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

## Установка

```bash
export TF_VAR_folder_id=<folder id>
terraform init && terraform apply
sudo tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes --force-reauth
eval "$(terraform output -raw elastic_credentials_command)"
eval "$(terraform output -raw app_credentials_command)"
```

Traefik в оба контекста, chart 41.6.0: `-f traefik-elastic-values.yaml` в контексте `elastic`, `-f traefik-app-values.yaml` в контексте `app`.

vmks только в `app` (команда в [AGENTS.md](AGENTS.md)). Затем в `app`:

```bash
kubectl --context app apply -f manifests/vminsert/nlb.yaml
```

ECK и exporter только в `elastic`:

```bash
helm --kube-context elastic upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --create-namespace --version 3.5.0 --set replicaCount=3
./scripts/apply-eck.sh
kubectl --context elastic apply -f manifests/exporter/elasticsearch-exporter.yaml
kubectl --context elastic apply -f manifests/vmagent/vmagent.yaml
```

Chaos Mesh 2.8.4 в оба контекста: `-f chaos-mesh-elastic-values.yaml` и `-f chaos-mesh-app-values.yaml`.

loadgen в `app`: `helm --kube-context app upgrade --install loadgen loadgen/chart --namespace load --create-namespace`.

## Прогон

Перед первым разом на каждой node group, которую будут изолировать:

```bash
kubectl config use-context elastic
./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)" ru-central1-a elastic-a
```

То же для `elastic-b`, `elastic-d` и, в контексте `app`, для `app-a`, `app-b`, `app-d`. `VERDICT: RECREATE` — isolate/restore не использовать.

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
