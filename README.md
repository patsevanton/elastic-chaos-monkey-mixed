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
| Grafana ×1 / Traefik ×3 | `vmks` / `traefik` |
| VMCluster RF=3 | vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ |
| Rally VM | `ru-central1-e`, 8 vCPU / 16 ГБ, SSD 150 ГиБ, без публичного IP |
| Headscale VM | `ru-central1-a`, `10.0.0.0/24`, 2 vCPU / 4 ГБ, HDD 20 ГиБ, единственный публичный IP, subnet router |

Инфра подробно: [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

## Шаг 0. Кластер, Headscale и vmks

```bash
export TF_VAR_folder_id=<folder id>
terraform init
terraform apply
```

В Terraform явно закреплены внутренние адреса: Traefik `10.0.1.33` (Grafana, Kibana, Chaos Dashboard) и ES NLB `10.0.1.5`. После полного `terraform destroy` и нового `terraform apply` эти IP повторно запрашиваются из тех же подсетей. Если адрес уже занят другим ресурсом, apply остановится, а не выдаст другой IP. Перед изменением работающего стенда проверьте `terraform plan`: существующий адрес Traefik не должен заменяться. На текущем стенде `10.0.1.5` пока занят эфемерным адресом CCM; не применяйте создание нового reserved address поверх работающего ES NLB. Применяйте конфигурацию после штатного удаления стенда (CCM сначала удалит NLB); миграция без простоя здесь не предусмотрена. Публичный IP Headscale при destroy/apply не сохраняется.

Ключ ноутбука и вход в tailnet (канон — output `headscale_login_command`):

```bash
terraform output -raw headscale_login_command
sudo tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes --force-reauth
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force
```

```bash
helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
  --namespace traefik --create-namespace \
  --version 41.6.0 \
  -f traefik-values.yaml
kubectl create namespace vmks --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/chaos-mesh/rbac.yaml
kubectl -n vmks wait --for=jsonpath='{.data.token}' secret/chaos-mesh-admin-token --timeout=60s
helm upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-values.yaml
kubectl apply -f manifests/exporter/traefik-scrape.yaml
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

Internal NLB ES `10.0.1.5:9200`: на него идёт нагрузка с Rally VM, внутри кластера Kibana и exporter используют ClusterIP сервиса `chaos-es-http`. Kibana — Ingress без basic auth. Если Kibana показывает свой логин — пользователь `elastic`, пароль:

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
  -f chaos-mesh-values.yaml
kubectl apply -f manifests/exporter/chaos-mesh-scrape.yaml
```

Chaos Dashboard: `terraform output chaos_dashboard_url`. Войти с токеном ServiceAccount из namespace `vmks`:

```bash
kubectl -n vmks get secret chaos-mesh-admin-token -o jsonpath='{.data.token}' | base64 -d; echo
```

Grafana provision-ит datasource `Chaos Mesh` с тем же токеном из Secret: через Explore доступны события экспериментов (`Applied`, `Recovered`, ошибки) из API Dashboard. Отдельный дашборд для событий не нужен. Из внешних дашбордов vmks скачивает Elasticsearch Exporter Cluster (mixin v1.9.0), Elasticsearch Exporter Quickstart (14191) и Traefik Official Kubernetes (`defaultDashboards.sources` в `vmks-values.yaml.tftpl`). У двух последних datasource выбирается переменной Prometheus: VictoriaMetrics. Quickstart использует старые панели `graph`/`singlestat`, которые Grafana мигрирует при загрузке; внешний вид проверьте после установки. Для Traefik метрики собираются с сервиса `traefik-metrics` через VMServiceScrape.

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

Индекс: `osmlinestrings` (20 532 036 документов). `osmpolygons` и `osmmultilinestrings` в challenge закомментированы и не заливаются — их корпуса не скачиваются. 1 primary, 2 replica — challenge/track-params. Challenge `append-no-conflicts-big`. `mvt-grid` в архиве трека нет. Трек разворачивается из архива `rally-tracks-nomvt-8500-v4.tar.gz` (cloud-init), заливаемого в S3; `base-url` корпусов `geoshape` указывает на S3, а не на `rally-tracks.elastic.co`.

`force-merge-linestrings` идёт в режиме `mode: polling` (`poll-period: 10`): вместо одной многоминутной HTTP-запроски — запуск задачи и короткие опросы `tasks.get`. Иначе обрыв соединения (pod-kill, `disable-zones`) валит `race` целиком. Вместе с `--on-error=continue-on-network` (см. ниже) сетевые обрывы не прерывают прогон — они попадают в error-rate.

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
  --on-error=continue-on-network \
  > ~/rally-ingest.log 2>&1 &
echo \$! > ~/rally-ingest.pid
EOF
./scripts/chaos-loop.sh
```

`chaos-loop.sh` крутит слот, пока жив `~/rally-ingest.pid`: pod kill (apply → 20 с → wait ready → delete) → loss 30% 900 с → пауза 60 с → delay 500 мс 900 с → пауза 60 с → `isolate-zone-b.sh` на `HOLD` (умолч. 900 с) → `restore-zone-b.sh` → снова. `HOLD` действует только на этап isolate. Одновременно не больше одной mixed-ноды.

Агент `chaos-check` — проверка каждого шага отдельно, не все команды разом:

- после `kubectl apply` Chaos CR: `./scripts/check-chaos.sh <kind> <name>` (для `es-network-loss` и `es-network-delay`);
- после `isolate-zone-b.sh`: `./scripts/check-zone-b-down.sh`.

```bash
./scripts/check-chaos.sh networkchaos es-network-loss
./scripts/check-chaos.sh networkchaos es-network-delay
./scripts/check-zone-b-down.sh
```

**Надо перепроверить:** у PodChaos `duration: 1s`, а `check-chaos.sh` требует `phase=Injected` — для `es-pod-kill` проверка почти наверняка не успевает поймать фазу.

NetworkChaos по смыслу эксперимента — деградация в **оба** направления (`both`). **Надо перепроверить:** в `manifests/chaos/network-loss.yaml` и `network-delay.yaml` поле `direction` не задано.

`check-zone-b-down.sh` успешен только если нода не Ready, VM **`RUNNING`**, InternalIP не отвечает на ping, а на обоих NLB (`chaos-es-http` и `traefik`) зона `b` есть в `disable_zone_statuses` и target ноды помечен `zone_shifted`. VM `RUNNING`, а не `STOPPED`, — это и отличает нашу изоляцию от preemptible-отвала Яндекса. Если изоляция слетела — это не конец слота, `script-runner` снова вызывает `isolate-zone-b.sh`.

Пока зона `b` изолирована: **yellow**, третья replica не на `a`/`d`. Grafana/Kibana/Traefik живы в `a` и `d`. Rally VM в `e` не трогаем. После restore replica едет на `b` сама.

После ingest:

- `scripts/check-count.sh` — `_count` индекса vs accepted bulk. Переменные: `ES_URL` (умолч. `http://127.0.0.1:9200`), `INDEX` (умолч. `osmlinestrings`); аргумент `$1` — число успешно принятых bulk из отчёта Rally.
- `scripts/sample-mget.sh` — выборка id из id-лога и проверка наличия документов. Переменные: `ES_URL`, `INDEX`, `ID_LOG` (умолч. `$HOME/id-log/bulk-ids.txt`); аргумент `$1` — размер выборки N (умолч. 20). **Надо перепроверить:** кто пишет `bulk-ids.txt` — в репозитории видно только `mkdir` каталога `~/id-log` в cloud-init, сам файл, судя по всему, пишет трек `rally-tracks-nomvt-8500-v4.tar.gz`.

Стоп-кран: убить Rally, `restore-zone-b.sh`, снять Chaos CR.

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
