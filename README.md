# Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally

Кластер Elasticsearch из трёх mixed-нод в трёх зонах Yandex Cloud должен переживать убийство пода, деградацию сети и отвал целой AZ — при живой индексации и поиске, без потери уже принятых документов. В этой статье — стенд на ECK, нагрузка Elastic Rally (`nyc_taxis`), Chaos Mesh и `yc compute instance stop` зоны `ru-central1-b`.

Критерии: search жив, index жив, нет потери документов, которые bulk принял до сбоя. Порога «жив / не жив» нет: в таблицы печатаем процент ошибок Rally.

## Почему трёх нод мало без zone awareness

Три master+data в трёх AZ и `number_of_replicas: 2` ещё не значат «зона может умереть». Без `cluster.routing.allocation.awareness.attributes: zone` Elasticsearch может положить primary и replica в одну зону. Тогда stop зоны `b` забирает больше одной копии.

С awareness primary и две replica разъезжаются по `ru-central1-a` / `b` / `d`. С `cluster.routing.allocation.awareness.force.zone.values` третья копия **не** переезжает на живую зону, пока `b` выключена: кластер **yellow**, по одной копии в `a` и `d`. Search и bulk идут. После `start` replica садится на `b` сама. Ручной relocate не нужен.

ECK HTTP без TLS. Пароль для Rally не нужен: anonymous `superuser` на HTTP. Transport между нодами — как в ECK. Elasticsearch в интернет не публикуем: Rally ходит на internal NLB `:9200`.

## Стенд

Terraform: Managed K8s **1.33**, SA `elastic-chaos-monkey`, три node group по одной preemptible-ноде **8 vCPU / 16 ГБ**, диск ноды **HDD**, без публичного IP. Egress private-подсетей — один Yandex NAT Gateway. Зоны worker’ов: `a`, `b`, `d`. PVC Elasticsearch — **yc-network-ssd 100 ГиБ** (исключение из HDD).

| Компонент | Куда |
|---|---|
| Elasticsearch 9.5.4 mixed ×3 | по поду в `a` / `b` / `d`, heap 3 ГиБ, RAM 6 ГиБ, CPU 4–6 |
| Kibana 9.5.4 ×3 | те же зоны, HTTP без TLS, Ingress без basic auth |
| ECK operator 3.5.0 ×3 | `elastic-system` |
| Chaos Mesh 2.8.4, controller ×3 | `chaos-mesh` |
| elasticsearch_exporter ×3 | `elastic` |
| Grafana / Traefik ×3 | `vmks` / `traefik` |
| VMCluster RF=3 | vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ |
| Rally VM | `ru-central1-e`, 8 vCPU / 16 ГБ, HDD 100 ГиБ, без публичного IP |
| Headscale VM | `ru-central1-a`, `10.0.0.0/24`, 2 vCPU / 4 ГБ, HDD 20 ГиБ, единственный публичный IP, subnet router |

Инфра подробно: [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

## Шаг 0. Кластер, Headscale и vmks

```bash
terraform init
terraform apply
```

Перед `terraform apply` положите `headscale_0.29.3_linux_amd64.deb` в корень
проекта — он копируется на Headscale VM (в git не коммитится).

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

Grafana и Kibana: `terraform output grafana_url` / `kibana_url`. Пароль Grafana:

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
```

## Шаг 3. Ingest nyc_taxis, затем mixed

SSH на Rally (`terraform output -raw rally_internal_ip`) после `tailscale up --accept-routes`. ES:

```bash
export ES_URL=http://$(kubectl -n elastic get svc chaos-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9200
```

(IP NLB с ноутбука через kubectl; на VM подставьте тот же адрес.)

Индекс: 1 primary, 2 replica. У трека `nyc_taxis` это задаётся challenge/track-params:

```bash
source ~/venv/bin/activate
esrally race --track=nyc_taxis --pipeline=benchmark-only \
  --target-hosts="${ES_URL#http://}" \
  --track-params='number_of_shards:1,number_of_replicas:2' \
  --challenge=append-no-conflicts
```

После ingest: `scripts/check-count.sh`. Дальше 4–6 часов mixed bulk+search (свой schedule поверх залитого индекса; id успешных bulk — в `~/id-log/bulk-ids.txt`). Нагрузку не останавливаем на время хаоса.

## Три опыта (~30–40 мин каждый)

Одновременно бьём не больше одной mixed-ноды. Preemptible: чужой stop Yandex — не эксперимент.

### 1. Pod kill

```bash
kubectl apply -f manifests/chaos/pod-kill.yaml
```

Один ES-под. ECK поднимает его сам. Смотрим health, unassigned, % ошибок Rally, `_count` vs принятые bulk, `scripts/sample-mget.sh`.

### 2. Сеть, только зона b

```bash
kubectl apply -f manifests/chaos/network-loss.yaml
# ~15 мин, затем
kubectl delete -f manifests/chaos/network-loss.yaml
# пауза, чистая сеть
kubectl apply -f manifests/chaos/network-delay.yaml
# ~15 мин
kubectl delete -f manifests/chaos/network-delay.yaml
```

Loss 30%, затем delay 500 мс на ES в `ru-central1-b`.

### 3. Отвал зоны b

```bash
./scripts/stop-zone-b.sh
# держим выключенной часть слота
./scripts/start-zone-b.sh
```

Пока нода мертва: **yellow**, третья replica не на `a`/`d`. Grafana/Kibana/Traefik живы в `a` и `d`. Rally VM в `e` не трогаем. После start replica едет на `b` сама.

Стоп-кран: остановить Rally, `start-zone-b.sh`, снять Chaos CR.

## Результаты

| Слот | cluster health | search error-rate | bulk error-rate | `_count` vs accepted | mget missing |
|---|---|---|---|---|---|
| baseline | green | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| pod kill | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| network loss 30% | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| network delay 500 мс | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| stop ru-central1-b | yellow | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |
| после start b | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ | _заполнить_ |

Grafana: `elasticsearch_cluster_health_status`, unassigned shards, exporter latency. Проценты Rally — с VM в таблицу руками.
