# Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally

Дата: 2026-09-18  
Репозиторий: `elastic-chaos-monkey-mixed`  
Формат: README = статья (как `k8s-descheduler-node-downscale`). Подход реализации: A — пошаговый стенд, хаос вручную.

## Цель

Стенд и статья доказывают, что Elasticsearch на трёх mixed-нодах в трёх зонах при прод-подобной нагрузке переживает:

1. убийство одного ES-пода;
2. деградацию сети (loss, затем delay) на ES-поде в одной зоне;
3. отвал зоны Yandex Cloud (`ru-central1-b`).

Критерии (все три): search жив, index жив, нет потери документов, успешно принятых bulk до сбоя. Порога «жив / не жив» по error-rate нет: в статье печатаем процент ошибок Rally.

## Вне скоупа

- IOChaos и отдельный «stop одной ноды без зоны» (в зоне одна нода: stop worker’а `b` = отвал AZ).
- Сравнение mixed vs dedicated, ECK vs Helm, второй ES-кластер.
- Публичный Elasticsearch, TLS/пароль на HTTP ES.
- Chaos Mesh Workflow как оркестратор трёх опытов.
- Автотесты хаоса в CI.
- Цифры результатов до прогона (в README плейсхолдеры).

## Архитектура

### Kubernetes

- Yandex Managed K8s **1.33**, Terraform.
- Service account: `elastic-chaos-monkey` (имя не копировать из других репозиториев).
- Три node group, по одной preemptible-ноде **8 vCPU / 16 ГБ**, загрузочный диск **HDD**, **без публичного IP**, NAT Gateway + Route Table.
- Зоны worker’ов: `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.
- Каркас сети/k8s/vmks/Traefik/sslip.io — как в существующих k8s-статьях автора, не копия имён SA.

Исключение из инфрах-правила HDD: **PVC Elasticsearch — `yc-network-ssd`**. Ноды k8s и диск Rally VM — HDD.

### Elasticsearch (ECK)

- Последние стабильные Elasticsearch **9.x** и ECK на момент реализации; номера в README и манифестах конкретные.
- Три mixed-ноды (master + data + ingest), по одной в зоне (`a` / `b` / `d`).
- PVC **100 ГиБ** `yc-network-ssd` на ноду.
- CPU: requests **4**, limits **6**. RAM requests **6 ГиБ**, heap **3 ГиБ**.
- Индекс нагрузки: **1 primary + 2 replica**.
- `cluster.routing.allocation.awareness.attributes: zone`.
- `cluster.routing.allocation.awareness.force.zone.values: a,b,d`.
- HTTP: **без TLS и без пароля**. Transport между нодами — как в ECK по умолчанию.
- Доступ Rally: Service **internal LoadBalancer** (NLB в VPC), порт **9200**. ES в интернет не публикуем.

Пока зона `b` выключена: кластер **yellow**, третья replica **не** аллоцируется на `a`/`d`. После `start` ноды `b` replica садится на `b` сама. Ручной relocate шардов не делаем.

### Rally

- Отдельная VM в **`ru-central1-e`**: **8 vCPU / 16 ГБ**, HDD **100 ГиБ**, **единственный публичный IP** среди compute (кроме балансировщика Traefik).
- Cloud-init: esrally, каталог id-лога успешных bulk.
- Трек: **nyc_taxis**. Сначала полный ingest, затем **4–6 часов** непрерывный mixed bulk+search.
- Зону `e` в экспериментах не стопаем.

### Наблюдение

- `victoria-metrics-k8s-stack` в namespace **`vmks`**.
- VMCluster **replicationFactor: 3**, по одному `vmstorage` в `a`/`b`/`d`: **1 vCPU / 2 ГиБ RAM / HDD 30 ГиБ**.
- В values отключить scrape-job и recording-правила control-plane Yandex Managed K8s (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, группы `etcd`, `kubernetes-system-scheduler`, `kubernetes-system-controller-manager`, `kube-scheduler.rules`).
- Grafana: **3 реплики** в `a`/`b`/`d`, Traefik + sslip.io.
- Traefik: **3 реплики** в `a`/`b`/`d`, публичный IP только у балансировщика.
- `prometheus-community/elasticsearch_exporter`: **3 реплики** в `a`/`b`/`d`.
- ECK operator и Chaos Mesh controller: **по 3 реплики**.
- Kibana (ECK): **3 реплики** в `a`/`b`/`d`, Ingress Traefik + sslip.io, **basic auth только на Ingress** (Secret не в git). Kibana ходит в ES без пароля. Stack Monitoring не заменяет Grafana.

### Хаос

Инструменты: Chaos Mesh (под, сеть) + `yc compute instance stop/start` (зона). Не Litmus.

Последовательность на фоне mixed (каждый слот **~30–40 мин**):

1. **Pod kill** — один раз один ES-под, ждать восстановления ECK (не цикл Chaos Monkey).
2. **Сеть** — только ES-под в **`ru-central1-b`**: NetworkChaos **loss 30%**, откат, пауза, затем **delay 500 мс**, откат.
3. **Зона `b`** — `yc compute instance stop` единственной ноды node group `b`, держать выключенной, затем `start`. Grafana/Traefik/exporter/ECK/Kibana живы в `a` и `d`.

Кворум: одновременно не больше одной mixed-ноды. Два master сразу — вне статьи.

## Потоки данных

- Rally VM → internal NLB `:9200` → три ES-пода. Kibana в путь нагрузки не входит.
- elasticsearch_exporter → ES HTTP без auth → vmagent → VMCluster. Grafana читает VM.
- Проценты ошибок Rally — с VM в таблицы README вручную.
- Браузер → Traefik (sslip.io) → Ingress basic auth → Kibana → ES без пароля.
- Chaos Mesh целится только в ES в зоне `b`. AZ-outage — stop/start VM node group `b`.

## Проверка потери данных (после каждого слота)

1. Счётчик успешных bulk vs `GET _count`.
2. Id-лог на Rally VM + sample/`mget`.
3. Error-rate Rally (search и bulk отдельно), печатаем % без порога.

## Ошибки, откат, безопасность

- Откат NetworkChaos: удалить CR, дождаться чистой сети.
- PodChaos one-shot: откат = ECK поднимает под.
- Зона `b`: только `yc compute instance start` той же VM, не `terraform apply`, не удаление node group.
- Стоп-кран mixed: остановить Rally, включить `b`, снять Chaos CR. Автоabort по SLO нет.
- Preemptible: посторонний stop Yandex не считать экспериментом; прогон короче ~24 ч. Убита не `b` во время слота — слот перезапустить.
- PVC ES зональные SSD: при stop `b` том остаётся в `b`, под не едет в `a`/`d`.
- Публично: Grafana, Kibana (basic auth на Ingress), SSH на Rally VM. ES — только VPC + internal NLB.

## Состав репозитория

Terraform в корне: `versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `net.tf`, `k8s.tf`, `ip-dns.tf`, `monitoring.tf`, `vmks-values.yaml.tftpl`, `rally-vm.tf`.

Манифесты:

- `manifests/eck/` — operator, Elasticsearch CR, Kibana CR.
- `manifests/chaos/` — PodChaos, NetworkChaos loss, NetworkChaos delay.
- `manifests/exporter/` — elasticsearch_exporter.
- `manifests/ingress/` — Ingress Kibana + middleware basic auth.

`scripts/` — stop/start ноды группы `b`, сверка bulk vs `_count`, sample mget.

`README.md` — полный текст статьи, H1: **Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally**. Таблицы результатов — плейсхолдеры до прогона.

## Проверка стенда

После apply: три ноды `a/b/d`; ES 3 пода, health green, шарды по зонам; Kibana и Grafana по sslip.io (Kibana после basic auth); Rally VM достукивается до NLB `:9200` без TLS/пароля.

Нагрузка: ingest `nyc_taxis` завершается; `_count` согласован с треком; mixed стартует, id-лог пишется.

Опыты — ручной прогон, не CI.

## Реализация

После утверждения этого файла — план реализации (writing-plans), затем код. Implementation не начинать из этого spec без отдельного плана и явного «да» на план.
