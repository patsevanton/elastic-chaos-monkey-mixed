# Отказоустойчивость Elasticsearch: два кластера, Chaos Mesh и изоляция зоны

Дата: 2026-09-30 (объединено из спек 2026-09-24 «два кластера» и 2026-09-25 «master/data split»)
Репозиторий: `elastic-chaos-monkey-mixed`
Доступ с ноутбука — публичные IP внешних NLB Traefik и внешние endpoint API master.

Формат: README = статья. Подход реализации: пошаговый стенд, хаос скриптом, не CI.

## Цель

Два кластера Yandex Managed Kubernetes в одной VPC. Приложение в app-кластере пишет и читает Elasticsearch в es-кластере. Elasticsearch — dedicated master и data: изоляция одной зоны гасит обе роли этой зоны и оставляет кворум master (живы 2 из 3). Стенд показывает, что запись и поиск переживают, по очереди в каждой зоне `ru-central1-a`, `ru-central1-b`, `ru-central1-d`:

1. pod-kill подов этой зоны;
2. network loss на подах этой зоны;
3. network delay на подах этой зоны;
4. сетевую изоляцию зоны (VM остаётся `RUNNING`).

Шаги 1–3 — проблемы на железках, пока зона доступна. Шаг 4 — отвал зоны. Оба кластера ломаются в одном проходе, одновременно, одной и той же зоной. Шаги не накладываются.

Критерии: search жив, index жив, нет потери документов, которые bulk принял до сбоя. Порога «жив / не жив» по error-rate нет: печатаем процент ошибок приложения. Пока зона изолирована, кластер **yellow** (копия шарда этой зоны не аллоцируется на живые зоны); после restore — **green**, копия садится сама.

Доступ с ноутбука: k8s API обоих кластеров — внешние endpoint master; Grafana и Kibana — публичные IP внешних NLB Traefik.

## Вне скоупа

- Power-off VM (`yc compute instance stop`).
- IOChaos, StressChaos, Chaos Mesh Workflow как оркестратор.
- Сравнение mixed vs dedicated как отдельный эксперимент (эта спека уже выбрала dedicated). ECK vs Helm, второй ES-кластер.
- Публичный Elasticsearch, TLS на HTTP ES.
- Смена версии Kubernetes (остаётся 1.33), Elasticsearch, ECK, Traefik.
- Изменение кластера `app` (размеры нод, число node group, приложение).
- Состав полей документа — спросить в следующий раз. Размер документа уже задан: 2 КБ.

## Архитектура

### Сеть

Одна VPC. Подсети `10.0.1.0/24` (`a`), `10.0.2.0/24` (`b`), `10.0.3.0/24` (`d`) общие для обоих кластеров. Egress приватных подсетей — один NAT Gateway и route table.

### Kubernetes

Два Yandex Managed K8s **1.33**. Service account: `elastic-chaos-monkey`. Terraform в k8s API не ходит.

`elastic`: шесть node group — master по одной preemptible-ноде, data по две (итого 9 нод), загрузочный диск **HDD**, **без публичного IP**. `app`: три node group, по одной preemptible-ноде (итого 3 ноды). API master обоих кластеров — внешний endpoint (`public_ip = true`), осознанное исключение из правила «ноды без публичного IP». Зоны: `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.

| Кластер | Роль | Нода |
|---|---|---|
| es master | master | 2 vCPU / 4 ГБ, HDD |
| es data | data | 4 vCPU / 8 ГБ, HDD |
| app | worker | 2 vCPU / 8 ГБ, HDD |

Группы `elastic-master-a|b|d` и `elastic-data-a|b|d`, плюс `app-a|b|d`. `lifecycle.ignore_changes` на `security_group_ids` у каждой из девяти групп.

Все диски — HDD, включая PVC Elasticsearch.

### Elasticsearch (ECK)

- Elasticsearch **9.5.4**, ECK **3.5.0**.
- Один ресурс ECK, имя `elastic`, шесть nodeSet: `master-a|b|d` (count 1) и `data-a|b|d` (count 2). `nodeSelector` `topology.kubernetes.io/zone` на зону nodeSet.
- Master (`master-a|b|d`): `node.roles: ["master"]`, PVC **20 ГиБ** `yc-network-hdd`, CPU request/limit 1, RAM 2 ГиБ, heap 1 ГиБ (`-Xms1g -Xmx1g`).
- Data (`data-a|b|d`): `node.roles: ["data", "ingest"]`, PVC **50 ГиБ** `yc-network-hdd`, CPU request 2 / limit 4, RAM 4 ГиБ, heap 2 ГиБ. `node.attr.zone` — зона nodeSet. Awareness по зоне, force на три зоны.
- Voting-only и ingest на master нет. Coordinating-only нод нет.
- Индекс нагрузки: **1 primary + 2 replica**.
- HTTP: без TLS и без пароля (анонимный superuser). Transport — как в ECK по умолчанию.
- Сервис `elastic-es-http`: **ClusterIP**. Прямого internal NLB на `:9200` нет — путь через Traefik es-кластера.

Пока зона изолирована: кластер **yellow**, кворум master жив (2 из 3), копия шарда этой зоны не аллоцируется. После restore копия садится сама. Ручной relocate шардов не делаем. Два master сразу — вне эксперимента: изолируется одна зона.

### Приложение

Один Deployment в app-кластере, **60 реплик** (`loadgen/chart/values.yaml`, `replicaCount: 60`). Topology spread по зонам. Зону affinity не исключает: при изоляции реплики в этой зоне отваливаются, остальные остаются.

Один процесс: bulk и search в разных горутинах. Документ синтетический, **2 КБ**. Состав полей — спросить в следующий раз. Не geo.

Путь запроса:

```
app-под → internal NLB Traefik (es-кластер) → Elasticsearch
```

Прямой NLB Elasticsearch в путь не входит. Kibana в путь нагрузки не входит.

Запись и поиск с первой секунды прогона и до `terraform destroy`. Пока идёт запись, p99 поиска выше спокойного: refresh, merge и bulk на тех же нодах. Это ожидаемо, не баг.

### Наблюдение

`victoria-metrics-k8s-stack` **0.92.1** в namespace **`vmks`** в **обоих** кластерах.

- `app`: полный стек. VMCluster **replicationFactor: 3**, по одному `vmstorage` в `a`/`b`/`d`: **500m vCPU / 1 ГиБ RAM / HDD 30 ГиБ**. Grafana **1 реплика**, Ingress публичного NLB Traefik app.
- `elastic`: тот же chart без Grafana и без VMCluster (`vmks-elastic-values.yaml`). vmagent чарта пишет remote write на `http://10.0.1.35:8480/insert/0/prometheus`. Второй vmagent не ставить.
- В values обоих кластеров отключить scrape-job и recording-правила control-plane Yandex Managed K8s.
- Traefik: chart **41.6.0**, **3 реплики** в `a`/`b`/`d`. На каждом кластере два Service: internal NLB и публичный NLB.

Метрики приложения — Prometheus, scrape vmagent app-кластера.

Метрики Elasticsearch: helm-чарт `prometheus-community/prometheus-elasticsearch-exporter` **7.4.0** в es-кластере, **3 реплики** в `a`/`b`/`d`, `serviceMonitor.enabled: true`. vmagent es-кластера пишет в `vminsert` app-кластера, не в vmagent app. `vminsert` — internal NLB `10.0.1.35:8480`. Grafana читает `vmselect`.

Скрейп-конфигурация задаётся стандартными `ServiceMonitor` (`monitoring.coreos.com/v1`) — для экспортёра, Traefik и goldpinger. CRD ставит чарт `prometheus-community/prometheus-operator-crds` **32.0.1** в оба кластера; `ServiceMonitor` собирает конвертер VM-оператора (сам prometheus-operator не ставится). `manifests/exporter/chaos-mesh-scrape.yaml`, `cilium-scrape.yaml` и loadgen в своём чарте остаются `VMServiceScrape`.

В es-кластере свой Traefik: chart **41.6.0**, 3 реплики. Internal NLB (`10.0.1.33`) — путь loadgen → Elasticsearch. Публичный NLB — Kibana с ноутбука. Kibana ×3, Ingress без basic auth. Grafana с ноутбука — публичный NLB Traefik `app`, не `10.0.1.34`.

ECK operator и Chaos Mesh controller: по 3 реплики в своём кластере. Chaos Mesh — в обоих кластерах.

### goldpinger и Cilium

Кластеры на Cilium CNI. В обоих кластерах — goldpinger **1.1.3** (image `bloomberg/goldpinger:3.11.3`), DaemonSet в namespace `goldpinger`: поды пингуют друг друга и отдают метрики на `:8080`. Метрики обоих кластеров сходятся в VictoriaMetrics кластера `app` (в `elastic` vmagent remote-write на `vminsert`).

Скрейп: `ServiceMonitor` goldpinger (`serviceMonitor.enabled` в values чарта, namespace `goldpinger`) и `manifests/exporter/cilium-scrape.yaml` (VMServiceScrape `cilium-agent`, порт `metrics` :9090, namespace `kube-system`) — в обоих кластерах. Дашборды: `goldpinger.json`, `cilium-node-latency.json`. Дашборд «Cilium Node Connectivity Latency» питается `cilium_node_connectivity_latency_seconds` от `cilium-agent`. `cilium-operator` (:6942) и `hubble-relay` пока не скрейпятся — см. [TODO.md](../../../TODO.md).

### Хаос

Инструменты: Chaos Mesh (под, сеть) и сетевая изоляция зоны. Не Litmus. Не power-off.

Порядок зон: `a`, затем `b`, затем `d`. На каждом шаге оба кластера одновременно.

Для каждой зоны четыре шага, каждый **2 минуты** (`STEP_SECONDS` в `scripts/chaos-run.sh`, `duration: 2m` в NetworkChaos), между любыми двумя шагами **5 минут покоя** (`QUIET_SECONDS=300`). В покое нет Chaos Mesh и нет изоляции. Запись и поиск идут и в шаге, и в покое.

1. **Pod-kill** — 2 минуты, kill каждые 30 секунд. Цель: поды loadgen и поды Elasticsearch в этой зоне (master и data).
2. **Network loss 30%** — 2 минуты, те же поды.
3. **Network delay 500 мс** — 2 минуты, те же поды.
4. **Изоляция зоны** — 2 минуты. Пустой SG `zone-isolation` на node group `elastic-master-*`, `elastic-data-*` и `app-*` этой зоны. VM остаётся `RUNNING`. `disable-zones` не используется: зона остаётся в балансировщиках, а трафик из неё снимает автоматический health-check NLB по нодам. Затем restore и следующий покой.

`disable-zones` пока не используется: изоляция — только пустой SG, трафик из зоны снимает health-check NLB по нодам. Если вернут — не чаще раза в 2 минуты на один NLB.

После pod-kill, loss и delay: Elasticsearch `health: green`, поды loadgen `Ready`, затем 5 минут покоя. После изоляции: restore, затем то же ожидание green и Ready, затем покой, затем следующая зона. Пока зона изолирована, green не требуется: кластер yellow по контракту awareness.

Одновременно не больше одной зоны.

SG переключается только CLI (`isolate` / `restore`), не `terraform apply`. У node group, которые изолируются, `lifecycle.ignore_changes` на `security_group_ids`. Контракт — [INFRASTRUCTURE.md](../../../INFRASTRUCTURE.md).

`yc managed-kubernetes node-group update` меняет security group на живой VM, не пересоздавая узел (hot-replace), поэтому отдельно проверять пересоздание не нужно.

Стоп-кран: остановить приложение, restore изолированной зоны, снять Chaos CR. Автоabort по SLO нет.

## Потоки данных

```
Ноутбук --интернет--> публичные IP внешних NLB Traefik и внешние endpoint API master
  → Grafana, Kibana
  → kubectl API обоих кластеров

app-под --VPC--> internal NLB Traefik es --> Elasticsearch ClusterIP :9200

elasticsearch_exporter --> ES HTTP
vmagent (es) --remote write--> internal NLB vminsert (app) --> VMCluster
vmagent (app) --> scrape приложения и vmks --> vminsert
Grafana --> vmselect
```

## Проверка потери данных

1. Счётчик успешных bulk приложения vs `GET _count` (через Grafana/VictoriaMetrics).
2. Выборка id и `mget`.
3. Error-rate bulk и search отдельно, печатаем % без порога.

Проверка после каждого шага, не только в конце прогона.

## Ошибки и откат

- NetworkChaos: удалить CR, дождаться чистой сети, green и Ready.
- Pod-kill: ECK поднимает под Elasticsearch; Deployment поднимает под приложения. Ждать green и Ready.
- Зона: только restore-скрипт (возврат SG), не `terraform apply`, не удаление node group, не power-off. `enable-zones` не вызывается, так как `disable-zones` не вызывается.
- Preemptible: посторонний stop Yandex не считать экспериментом. Убита не та зона во время слота — слот перезапустить.
- PVC ES зональные HDD: при изоляции зоны том остаётся в ней, под не едет в другую зону.

## Состав репозитория (целевой)

Удалить: `rally-vm.tf`, `cloud-init/rally.yaml`, подсеть `e` в `net.tf` и `locals.tf`, Rally из README, INFRASTRUCTURE, агентов и скриптов.

Добавить: Terraform app-кластера (те же подсети), Go-приложение и Helm chart, internal NLB `vminsert`, Ingress Elasticsearch через Traefik es-кластера, скрипт прогона четырёх шагов по трём зонам на обоих кластерах. goldpinger (DaemonSet, оба кластера) и cilium-scrape для наблюдаемости сети.

Chaos Mesh CR: pod-kill, loss 30%, delay 500 мс — для приложения и для Elasticsearch, селектор по зоне шага.

## Проверка стенда

После apply: девять нод `elastic` Ready (по зоне одна master и две data), три ноды `app` без изменений. ES green, шарды по зонам, роли `m` и `di` в каждой зоне; индекс шардов на data, awareness по зоне. Master-pod'ы с PVC 20 ГиБ, data-pod'ы с PVC 50 ГиБ. loadgen 60/60 Ready, bulk и search идут через NLB Traefik es. Remote write vmagent кластера `elastic` доходит до vminsert. Grafana в app-кластере видит метрики loadgen и Elasticsearch.

Опыты — ручной прогон, не CI. Цифры результатов в README — плейсхолдеры до прогона.

## Открыто

Состав полей синтетического документа (2 КБ) — спросить в следующий раз.