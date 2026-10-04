# Развёртывание инфраструктуры: Terraform

Два Yandex Managed Kubernetes 1.33 в одной VPC. `elastic`: шесть node group, master 2 vCPU / 4 ГБ и data 4 vCPU / 8 ГБ, по одной в `ru-central1-a`/`b`/`d`. `app`: три node group 2 vCPU / 8 ГБ, по одной в тех же зонах. Ноды preemptible, HDD, без публичного IP. Исключение: API master обоих кластеров — внешний endpoint (`public_ip = true` в `k8s.tf`/`k8s-app.tf`), осознанное решение для доступа с ноутбука. Egress приватных подсетей — один NAT Gateway. Публичные IP только у внешних NLB Traefik. Между кластерами — internal NLB Traefik.

Service account: `elastic-chaos-monkey`.

## Сеть

Подсети `10.0.1.0/24` (`a`), `10.0.2.0/24` (`b`), `10.0.3.0/24` (`d`) общие.

Reserved internal IP в подсети `a`: Traefik `elastic` `10.0.1.33`, Traefik `app` `10.0.1.34`, `vminsert` `10.0.1.35`. Публичные IP: внешний NLB Traefik `app` и `elastic`.

## Публичный доступ

Браузер → внешний NLB Traefik → entrypoint `public` → Ingress. `app`: Grafana, `grafana.<IP>.sslip.io`. `elastic`: Kibana, `kibana.<IP>.sslip.io`. Elasticsearch снаружи не публикуется: его Ingress на entrypoint `web` внутреннего NLB.

## Traefik

Chart **41.6.0**, 3 реплики. На каждом кластере два Service: internal NLB (`web`) и внешний NLB (`public`). Кластер `elastic`: `traefik-elastic-values.yaml`. Кластер `app`: `traefik-app-values.yaml`.

## VictoriaMetrics

Оба кластера, namespace `vmks`, chart **0.92.1**. `app`: Grafana 1 реплика, снаружи через публичный NLB Traefik, VMCluster RF=3, vmstorage HDD 30 ГиБ. `elastic`: тот же chart без Grafana — CRD оператора для `VMAgent`. Control-plane scrape и recording-правила выключены в обоих. `vminsert` публикуется Service `vminsert-nlb` на `10.0.1.35:8480`. vmagent кластера `elastic` пишет туда remote write, не в vmagent `app`.

Стандартные Prometheus CRD (`monitoring.coreos.com/v1`) ставит чарт `prometheus-community/prometheus-operator-crds` **32.0.1** в оба кластера (namespace `monitoring`) — до чартов, которые рендерят `ServiceMonitor` (Traefik, goldpinger, prometheus-elasticsearch-exporter). Сам prometheus-operator не ставится: `ServiceMonitor` собирает конвертер VM-оператора. Метрики Elasticsearch отдаёт helm-чарт `prometheus-community/prometheus-elasticsearch-exporter` **7.4.0** в кластере `elastic` (3 реплики, `serviceMonitor.enabled: true`).

## Изоляция зоны

Пустой SG `zone-isolation`. `lifecycle.ignore_changes` на `security_group_ids` у всех девяти node group. Переключение только `./scripts/isolate-zone.sh` / `./scripts/restore-zone.sh`. State: `.state/zone-isolate.env`.

Isolate ставит пустой SG на `elastic-master-*`, `elastic-data-*` и `app-*` этой зоны. `disable-zones` пока не используется: изоляция — только пустой SG, зона остаётся в балансировщиках, а трафик из неё снимает health-check NLB по нодам. VM остаётся `RUNNING`.

Restore возвращает сохранённые SG. `enable-zones` не вызывается, так как `disable-zones` не вызывается.

`yc managed-kubernetes node-group update` меняет security group на живой VM, не пересоздавая узел (hot-replace), поэтому отдельно проверять пересоздание не нужно. Применение SG к трём node group зоны идёт параллельно: три `yc node-group update` в фоне, скрипты ждут все три.

`disable-zones` не используется: изоляция зоны — только пустой SG, а трафик из зоны снимает автоматический health-check NLB по нодам. Если `disable-zones` понадобится вернуть, правило «не чаще раза в 2 минуты» действует на один NLB.

## Grafana и CloudNativePG

Grafana на кластере `app` — 3 реплики с `required` podAntiAffinity по `topology.kubernetes.io/zone` (жёстко по одной на зону `a`/`b`/`d`): гибель ноды зоны оставляет под Grafana `Pending` до восстановления ноды. Состояние (аннотации, пользователи, сессии) вынесено из SQLite в общий PostgreSQL — PVC у Grafana нет.

PostgreSQL: CloudNativePG, оператор chart **0.25.0** (оператор 1.26.1) в namespace `cnpg-system`, 2 реплики с anti-affinity по зонам. Кластер `pg-grafana` в namespace `vmks`: 3 инстанса PG **17.5-22**, `topologyKey` по зоне, PVC 10 ГиБ `yc-network-hdd`, образ `ghcr.io/cloudnative-pg/postgresql:17.5-22-bookworm`. Синхронная репликация `method: any`, `number: 1`, `dataDurability: preferred`. Без бэкапов. Границу кластера не расширяет, в chaos-сценарии не входит.

Подключение Grafana: `pg-grafana-rw.vmks.svc.cluster.local:5432`, БД `grafana`, пользователь `app`, пароль из секрета `pg-grafana-app`. Установка — `./scripts/apply-cnpg.sh` (идемпотентно).

## Аннотации Grafana

Изоляция SG и chaos-шаги отмечаются аннотациями в Grafana (`scripts/annotate-grafana.sh`, `POST /api/annotations`, basic-auth `admin` + secret `vmks-grafana`). `isolate-zone.sh`/`restore-zone.sh` ставят пару start/end на каждую изменяемую node group, `chaos-run.sh` — на шаги pod-kill, loss, delay и isolate. Теги: `chaos`/`sg`, зона, шаг, фаза. Дашборды (`cilium-node-latency`, `elasticsearch-cluster`, `elastic-loadgen-app`, `goldpinger`) показывают их слоем «Chaos» (фильтр по тегам `chaos`, `sg`). Недоступен Grafana API — прогон прерывается. Аннотации хранятся в PostgreSQL, поэтому переживают пересоздание подов Grafana.

## Требования

- yc CLI, Terraform >= 1.3, kubectl, Helm >= 3, `jq`, `curl`, `envsubst`

## Запуск

```bash
export TF_VAR_folder_id=<folder id>
terraform init
terraform apply
eval "$(terraform output -raw elastic_credentials_command)"
eval "$(terraform output -raw app_credentials_command)"
```
