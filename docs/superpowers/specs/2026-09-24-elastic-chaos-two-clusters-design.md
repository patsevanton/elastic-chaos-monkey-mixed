# Отказоустойчивость Elasticsearch: два кластера, Chaos Mesh и изоляция зоны

Дата: 2026-09-24  
Репозиторий: `elastic-chaos-monkey-mixed`  
Заменяет концепцию [2026-09-18-elastic-chaos-monkey-mixed-design.md](2026-09-18-elastic-chaos-monkey-mixed-design.md) в части Rally и одного прогона зоны `b`. Доступ через Headscale (2026-09-19) сохраняется, маршрут `10.0.4.0/24` убирается.

Формат: README = статья. Подход реализации: пошаговый стенд, хаос скриптом, не CI.

## Цель

Два кластера Yandex Managed Kubernetes в одной VPC. Приложение в app-кластере пишет и читает Elasticsearch в es-кластере. Стенд показывает, что запись и поиск переживают, по очереди в каждой зоне `ru-central1-a`, `ru-central1-b`, `ru-central1-d`:

1. pod-kill подов этой зоны;
2. network loss на подах этой зоны;
3. network delay на подах этой зоны;
4. сетевую изоляцию зоны (VM остаётся `RUNNING`).

Шаги 1–3 — проблемы на железках, пока зона доступна. Шаг 4 — отвал зоны. Оба кластера ломаются в одном проходе, одновременно, одной и той же зоной. Шаги не накладываются.

Критерии: search жив, index жив, нет потери документов, которые bulk принял до сбоя. Порога «жив / не жив» по error-rate нет: в статье печатаем процент ошибок приложения.

Доступ с ноутбука: k8s API обоих кластеров, Grafana и Kibana — только через Headscale. Публичный IP только у Headscale VM.

## Вне скоупа

- Rally, esrally, Rally VM, cloud-init Rally, подсеть `ru-central1-e` (`10.0.4.0/24`).
- Целевые 20 531 936 документов и 131,53 ГБ store. Размер документа фиксирован, объём индекса — сколько успеет залиться за прогон.
- Geo-запросы и корпус geoshape.
- Power-off VM (`yc compute instance stop`).
- Chaos Mesh на фоне уже изолированной зоны: контроллер до подов зоны не достучится.
- IOChaos, StressChaos, Chaos Mesh Workflow как оркестратор.
- Сравнение mixed vs dedicated, ECK vs Helm, второй ES-кластер.
- Публичный Elasticsearch, TLS на HTTP ES.
- Автотесты хаоса в CI.
- Headscale в Kubernetes. Tailscale на нодах k8s. Policy / ACL Headscale.
- Смена версии Kubernetes (остаётся 1.33) и ingress-nginx (его нет; вход — Traefik).
- Состав полей документа — спросить в следующий раз. Размер документа уже задан: 2 КБ.

## Архитектура

### Сеть

Одна VPC. Подсети `10.0.1.0/24` (`a`), `10.0.2.0/24` (`b`), `10.0.3.0/24` (`d`) общие для обоих кластеров. Egress приватных подсетей — один NAT Gateway и route table. Подсеть Headscale `10.0.0.0/24` без route table.

Подсеть `elastic-chaos-e` (`10.0.4.0/24`, `ru-central1-e`) удаляется: кроме Rally VM на ней ничего нет. Из advertise-routes и approve-routes Headscale убирается только `10.0.4.0/24`. Маршруты `10.0.1.0/24`–`10.0.3.0/24` остаются, иначе ноутбук теряет k8s API, Grafana и Kibana.

### Kubernetes

Два Yandex Managed K8s **1.33**. Service account: `elastic-chaos-monkey`. Terraform в k8s API не ходит.

Оба кластера: три node group, по одной preemptible-ноде, загрузочный диск **HDD**, **без публичного IP**, `master.public_ip = false`. Зоны: `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.

| Кластер | Нода |
|---|---|
| es | 8 vCPU / 16 ГБ, HDD |
| app | 2 vCPU / 4 ГБ, HDD |

Исключение из правила HDD: PVC Elasticsearch — `yc-network-ssd`. Ноды обоих кластеров и Headscale VM — HDD.

### Headscale

Без изменений относительно спеки 2026-09-19, кроме маршрута `10.0.4.0/24`. Один Headscale на оба кластера. Публичный IP только у Headscale VM.

### Elasticsearch (ECK)

- Elasticsearch **9.5.4**, ECK **3.5.0**.
- Три mixed-ноды (master + data + ingest), по одной в зоне `a` / `b` / `d`.
- PVC **100 ГиБ** `yc-network-ssd` на ноду.
- CPU: requests **4**, limits **6**. RAM requests **6 ГиБ**, heap **3 ГиБ**.
- Индекс нагрузки: **1 primary + 2 replica**.
- `cluster.routing.allocation.awareness.attributes: zone`.
- `cluster.routing.allocation.awareness.force.zone.values` — три зоны.
- HTTP: без TLS и без пароля. Transport — как в ECK по умолчанию.
- Сервис `chaos-es-http`: **ClusterIP**. Internal NLB на `:9200` убирается.

Пока зона изолирована: кластер **yellow**, копия этой зоны не аллоцируется на живые зоны. После restore копия садится сама. Ручной relocate шардов не делаем. `store.size` во время yellow не является условием остановки.

### Приложение

Один Deployment в app-кластере, **3 реплики**. Topology spread по зонам, `maxSkew: 1`. Зону `b` affinity не исключает: при изоляции реплика в этой зоне отваливается, две другие остаются.

Один процесс: bulk и search в разных горутинах. Документ синтетический, **2 КБ**. Состав полей — спросить в следующий раз. Не geo.

Путь запроса:

```
app-под → internal NLB Traefik (es-кластер) → Elasticsearch
```

Прямой NLB Elasticsearch в путь не входит. Kibana в путь нагрузки не входит.

Запись и поиск с первой секунды прогона и до `terraform destroy`. Пока идёт запись, p99 поиска выше спокойного: refresh, merge и bulk на тех же трёх нодах. Это ожидаемо, не баг.

### Наблюдение

`victoria-metrics-k8s-stack` **0.92.1** в namespace **`vmks`** только в **app-кластере**.

- VMCluster **replicationFactor: 3**, по одному `vmstorage` в `a`/`b`/`d`: **1 vCPU / 2 ГиБ RAM / HDD 30 ГиБ**.
- В values отключить scrape-job и recording-правила control-plane Yandex Managed K8s.
- Grafana: **1 реплика**, Ingress Traefik app-кластера.
- Traefik app-кластера: chart **41.6.0**, **3 реплики** в `a`/`b`/`d`, Service internal LoadBalancer.

Метрики приложения — Prometheus, scrape vmagent app-кластера.

Метрики Elasticsearch: `prometheus-community/elasticsearch_exporter` остаётся в es-кластере, **3 реплики** в `a`/`b`/`d`. vmagent es-кластера делает **remote write прямо в `vminsert`**, не в vmagent app-кластера. `vminsert` публикуется **internal NLB** в VPC (тот же приём, что у Traefik). Grafana читает `vmselect`.

В es-кластере свой Traefik: chart **41.6.0**, 3 реплики, internal NLB. Через него приложение ходит в Elasticsearch и браузер — в Kibana. Kibana ×3, Ingress без basic auth.

ECK operator и Chaos Mesh controller: по 3 реплики в своём кластере. Chaos Mesh — в обоих кластерах.

### Хаос

Инструменты: Chaos Mesh (под, сеть) и сетевая изоляция зоны. Не Litmus. Не power-off.

Порядок зон: `a`, затем `b`, затем `d`. На каждом шаге оба кластера одновременно.

Для каждой зоны четыре шага, каждый **10 минут**, между любыми двумя шагами **10 минут покоя**. В покое нет Chaos Mesh и нет изоляции. Запись и поиск идут и в шаге, и в покое.

1. **Pod-kill** — 10 минут, kill повторяется всё окно. Цель: поды приложения и поды Elasticsearch в этой зоне.
2. **Network loss 30%** — 10 минут, поды приложения и Elasticsearch в этой зоне.
3. **Network delay 500 мс** — 10 минут, те же поды.
4. **Изоляция зоны** — 10 минут. Пустой SG `zone-isolation` на node group этой зоны в **обоих** кластерах. VM остаётся `RUNNING`. На NLB Traefik es-кластера (путь app → ES) — `disable-zones` этой зоны. На NLB `vminsert` — тоже, иначе remote write из изолированной зоны es-кластера не отражает отвал. На app-кластере `disable-zones` нет: изоляции node group достаточно. Затем restore и следующий покой.

`disable-zones` не чаще раза в 2 минуты на один NLB.

После pod-kill, loss и delay: Elasticsearch `health: green`, поды приложения `Ready`, затем 10 минут покоя. После изоляции: restore, затем то же ожидание green и Ready, затем покой, затем следующая зона. Пока зона изолирована, green не требуется: кластер yellow по контракту awareness.

Одновременно не больше одной зоны. Два master сразу — вне эксперимента.

SG переключается только CLI (`isolate` / `restore`), не `terraform apply`. У node group, которые изолируются, `lifecycle.ignore_changes` на `security_group_ids`. Контракт — [INFRASTRUCTURE.md](../../../INFRASTRUCTURE.md).

Перед первым прогоном на кластере — `./scripts/verify-ng-sg-swap.sh` для node group, которые будут изолироваться. При `VERDICT: RECREATE` isolate/restore не использовать.

Стоп-кран: остановить приложение, restore изолированной зоны, снять Chaos CR. Автоabort по SLO нет.

## Потоки данных

```
Ноутбук --Headscale--> 10.0.1.0/24 … 10.0.3.0/24
  → internal API обоих кластеров
  → internal NLB Traefik app (Grafana)
  → internal NLB Traefik es (Kibana)

app-под --VPC--> internal NLB Traefik es --> Elasticsearch ClusterIP :9200

elasticsearch_exporter --> ES HTTP
vmagent (es) --remote write--> internal NLB vminsert (app) --> VMCluster
vmagent (app) --> scrape приложения и vmks --> vminsert
Grafana --> vmselect
```

## Проверка потери данных

1. Счётчик успешных bulk приложения vs `GET _count`.
2. Выборка id и `mget`.
3. Error-rate bulk и search отдельно, печатаем % без порога.

Проверка после каждого шага, не только в конце прогона.

## Ошибки и откат

- NetworkChaos: удалить CR, дождаться чистой сети, green и Ready.
- Pod-kill: ECK поднимает под Elasticsearch; Deployment поднимает под приложения. Ждать green и Ready.
- Зона: только restore-скрипт (SG + `enable-zones` на NLB es-кластера), не `terraform apply`, не удаление node group, не power-off.
- Preemptible: посторонний stop Yandex не считать экспериментом. Убита не та зона во время слота — слот перезапустить.
- PVC ES зональные SSD: при изоляции зоны том остаётся в ней, под не едет в другую зону.

## Состав репозитория (целевой)

Удалить: `rally-vm.tf`, `cloud-init/rally.yaml`, подсеть `e` в `net.tf` и `locals.tf`, Rally из README, INFRASTRUCTURE, агентов и скриптов (`chaos-loop.sh` в текущем виде, завязка на `rally-ingest.pid`).

Добавить: Terraform app-кластера (ноды 2 vCPU / 4 ГБ, те же подсети), Go-приложение и Helm chart, internal NLB `vminsert`, Ingress Elasticsearch через Traefik es-кластера, скрипт прогона четырёх шагов по трём зонам на обоих кластерах.

Chaos Mesh CR: pod-kill, loss 30%, delay 500 мс — для приложения и для Elasticsearch, селектор по зоне шага.

## Проверка стенда

После apply и join в tailnet: три ноды `a/b/d` в каждом кластере; ES green, шарды по зонам; приложение 3/3 Ready; bulk и search идут через NLB Traefik es; remote write es-vmagent доходит до vminsert; Grafana в app-кластере видит метрики приложения и Elasticsearch.

Опыты — ручной прогон, не CI. Цифры результатов в README — плейсхолдеры до прогона.

## Открыто

Состав полей синтетического документа (2 КБ) — спросить в следующий раз.
