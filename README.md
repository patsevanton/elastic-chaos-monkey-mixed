# Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally

Кластер Elasticsearch из трёх mixed-нод в трёх зонах Yandex Cloud должен переживать убийство пода, деградацию сети и отвал целой AZ — при живой индексации и поиске, без потери уже принятых документов. В этой статье — стенд на ECK, нагрузка Elastic Rally (`geoshape`), Chaos Mesh и сетевая изоляция зоны `ru-central1-b` (пустой Security Group на node group + `disable-zones` на NLB).

Критерии: search жив, index жив, нет потери документов, которые bulk принял до сбоя. Порога «жив / не жив» нет: в таблицы печатаем процент ошибок Rally.

## Почему трёх нод мало без zone awareness

Три master+data в трёх AZ и `number_of_replicas: 2` ещё не значат «зона может умереть». Без `cluster.routing.allocation.awareness.attributes: zone` Elasticsearch может положить primary и replica в одну зону. Тогда отвал зоны `b` забирает больше одной копии.

С awareness primary и две replica разъезжаются по `ru-central1-a` / `b` / `d`. С `cluster.routing.allocation.awareness.force.zone.values` третья копия **не** переезжает на живую зону, пока `b` изолирована: кластер **yellow**, по одной копии в `a` и `d`. Search и bulk идут. После `restore` replica садится на `b` сама. Ручной relocate не нужен.

ECK HTTP без TLS. Пароль для Rally не нужен: anonymous `superuser` на HTTP. Transport между нодами — как в ECK. Elasticsearch в интернет не публикуем: Rally ходит на internal NLB `:9200`.

## Стенд

Terraform: Managed K8s **1.33**, SA `elastic-chaos-monkey`, три node group по одной preemptible-ноде **8 vCPU / 16 ГБ**, диск ноды **HDD**, без публичного IP. Egress private-подсетей — один Yandex NAT Gateway. Зоны worker’ов: `a`, `b`, `d`. PVC Elasticsearch — **yc-network-ssd 100 ГиБ**, диск Rally VM — **network-ssd 150 ГиБ** (исключения из HDD).

| Компонент | Куда |
|---|---|
| Elasticsearch 9.5.4 mixed ×3 | по поду в `a` / `b` / `d`, heap 3 ГиБ, RAM 6 ГиБ, CPU 4–6 |
| Kibana 9.5.4 ×3 | те же зоны, HTTP без TLS, Ingress без basic auth |
| ECK operator 3.5.0 ×3 | `elastic-system` |
| Chaos Mesh 2.8.4, controller ×3 | `chaos-mesh` |
| elasticsearch_exporter ×3 | `elastic` |
| Grafana / Traefik ×3 | `vmks` / `traefik` |
| VMCluster RF=3 | vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ |
| Rally VM | `ru-central1-e`, 8 vCPU / 16 ГБ, SSD 150 ГиБ, без публичного IP |
| Headscale VM | `ru-central1-a`, `10.0.0.0/24`, 2 vCPU / 4 ГБ, HDD 20 ГиБ, единственный публичный IP, subnet router |

Инфра подробно: [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

## Шаг 0. Кластер, Headscale и vmks

```bash
terraform init
terraform apply
```

Ключ ноутбука и вход в tailnet:

```bash
terraform output -raw headscale_laptop_preauth
terraform output -raw headscale_login_command
tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force
chmod +x scripts/*.sh
```

```bash
helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
  --namespace traefik --create-namespace \
  --version 41.6.0 \
  -f traefik-values.yaml
helm upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-values.yaml
```

Grafana и Kibana: `terraform output grafana_url` / `kibana_url`. Логин Kibana: `terraform output kibana_user`. Пароли: `terraform output grafana_admin_password_command` / `kibana_elastic_password_command`. Пароль Grafana:

```bash
kubectl -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

## Шаг 1. ECK, Elasticsearch, Kibana

```bash
helm repo add elastic https://helm.elastic.co
helm upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --create-namespace \
  --version 3.5.0 \
  --set replicaCount=3
```

```bash
./scripts/apply-eck.sh
kubectl apply -f manifests/exporter/elasticsearch-exporter.yaml
```

Internal NLB: `kubectl -n elastic get svc chaos-es-http`. Kibana — Ingress без basic auth. Если Kibana показывает свой логин — пользователь `elastic`, пароль:

```bash
kubectl -n elastic get secret chaos-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo
```

```bash
kubectl -n elastic get elasticsearch chaos
kubectl -n elastic get pods -o wide
curl -s "$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9200/_cluster/health?pretty"
```

Ожидаем **green**, три ноды, шарды по зонам.

## Шаг 2. Chaos Mesh

Yandex Managed K8s — containerd:

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace \
  --version 2.8.4 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set controllerManager.replicaCount=3
kubectl apply -f manifests/exporter/chaos-mesh-scrape.yaml
```

Дашборды Elasticsearch (mixin экспортёра v1.9.0) и Chaos Mesh Overview chart vmks качает сам: `defaultDashboards.sources` в `vmks-values.yaml`. В Grafana у обоих выбрать datasource VictoriaMetrics. У Chaos Mesh Overview: Namespace `chaos-mesh`.

## Шаг 3. Заливка и хаос одновременно

Хаос и отвал зоны `b` идут **с первой секунды заливки** и крутятся циклом, пока Rally пишет в Elasticsearch. Не ждать конца ingest.

### Отвал зоны b

Зона `b` ломается **сетевой изоляцией**, а не power-off: VM остаётся `RUNNING`, отрезана сеть.

1. `scripts/isolate-zone-b.sh` пишет `.state/zone-b-isolate.env` (исходный список SG node group и id обоих NLB), вешает пустой SG `zone-isolation` на `elastic-chaos-b` через `yc managed-kubernetes node-group update` и делает `disable-zones ru-central1-b` на NLB `chaos-es-http` и `traefik`.
2. `scripts/restore-zone-b.sh` возвращает исходный список SG (здесь пустой) и `enable-zones` на обоих NLB.

SG заводит Terraform (`sg.tf`), переключает только CLI. Чтобы `terraform apply` не «чинил» эксперимент, у `k8s_node_group_b` стоит `lifecycle.ignore_changes` на `security_group_ids`. Ограничение ЯО: `disable-zones` не чаще раза в 2 минуты на один NLB.

Первый прогон на новом кластере — проверить, что смена SG не пересоздаёт узел:

```bash
./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)"
```

`VERDICT: HOT-SWAP` — работаем как есть. `VERDICT: RECREATE` — `node-group update` не годится для network partition, isolate/restore переписываются на `yc compute instance update-network-interface`.

Два агента, не один:

| Агент | Что делает | Чего не делает |
|---|---|---|
| `script-runner` | простые скрипты: `esrally`, `chaos-loop.sh`, `kubectl apply/delete`, `isolate-zone-b.sh`, `restore-zone-b.sh` | не проверяет результат |
| `chaos-check` | `check-chaos.sh`, `check-zone-b-down.sh` | не запускает хаос и не восстанавливает зону |

SSH на Rally (`terraform output -raw rally_internal_ip`) после `tailscale up --accept-routes`. ES:

```bash
export ES_URL=http://$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9200
```

(IP NLB с ноутбука через kubectl; на VM подставьте тот же адрес.)

Индекс: `osmlinestrings` (20 532 036 документов). `osmpolygons` и `osmmultilinestrings` в challenge закомментированы и не заливаются — их корпуса не скачиваются. 1 primary, 2 replica — challenge/track-params. Challenge `append-no-conflicts-big`. `mvt-grid` в архиве трека нет. Трек разворачивается из архива `rally-tracks-nomvt-8500-v3.tar.gz` (cloud-init), заливаемого в S3; `base-url` корпусов `geoshape` указывает на S3, а не на `rally-tracks.elastic.co`.

Агент `script-runner` стартует заливку в фоне, затем сразу цикл хаоса:

```bash
ssh -o BatchMode=yes ubuntu@$(terraform output -raw rally_internal_ip) 'bash -s' <<EOF
set -euo pipefail
export ES_URL=http://$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9200
source ~/venv/bin/activate
nohup esrally race --track=geoshape --pipeline=benchmark-only \
  --target-hosts="\${ES_URL#http://}" \
  --track-params='number_of_shards:1,number_of_replicas:2' \
  --challenge=append-no-conflicts-big \
  > ~/rally-ingest.log 2>&1 &
echo \$! > ~/rally-ingest.pid
EOF
./scripts/chaos-loop.sh
```

`chaos-loop.sh` крутит слот, пока жив `~/rally-ingest.pid`: pod kill → loss 30% 15 мин → пауза → delay 500 мс 15 мин → `isolate-zone-b.sh` на 15 мин → `restore-zone-b.sh` → снова. Одновременно не больше одной mixed-ноды.

Агент `chaos-check` после каждого `apply` и после `isolate-zone-b.sh`:

```bash
./scripts/check-chaos.sh podchaos es-pod-kill
./scripts/check-chaos.sh networkchaos es-network-loss
./scripts/check-chaos.sh networkchaos es-network-delay
./scripts/check-zone-b-down.sh
```

`check-zone-b-down.sh` успешен только если нода не Ready, VM **`RUNNING`**, InternalIP не отвечает на ping, а на обоих NLB (`chaos-es-http` и `traefik`) зона `b` есть в `disable_zone_statuses` и target ноды помечен `zone_shifted`. VM `RUNNING`, а не `STOPPED`, — это и отличает нашу изоляцию от preemptible-отвала Яндекса. Если изоляция слетела — это не конец слота, `script-runner` снова вызывает `isolate-zone-b.sh`.

Пока зона `b` изолирована: **yellow**, третья replica не на `a`/`d`. Grafana/Kibana/Traefik живы в `a` и `d`. Rally VM в `e` не трогаем. После restore replica едет на `b` сама.

После ingest: `scripts/check-count.sh`. Стоп-кран: убить Rally, `restore-zone-b.sh`, снять Chaos CR.

## Результаты

| Слот | cluster health | search error-rate | bulk error-rate | `_count` vs accepted | mget missing |
|---|---|---|---|---|---|
| baseline | green | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| pod kill | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| network loss 30% | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| network delay 500 мс | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| isolate ru-central1-b | yellow | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| после restore b | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |

Grafana: `elasticsearch_cluster_health_status`, unassigned shards, exporter latency. Проценты Rally — с VM в таблицу руками.
