# Отказоустойчивость Elasticsearch: два кластера — контракт стенда

> Стенд может быть собран, а может быть не собран. Порядок ниже описывает, что должно существовать и как это поднять с нуля. `terraform apply` идемпотентен (собран — `No changes`, не собран — создаёт). `./scripts/apply-eck.sh` можно применять повторно: при неизменных `nodeSets` это no-op. Хаос — только `./scripts/isolate-zone.sh` / `./scripts/restore-zone.sh` / `./scripts/chaos-run.sh`.

**Goal:** Два кластера `elastic` и `app`. В `elastic` — Elasticsearch dedicated master (3, PVC 20 ГиБ) + data (6, PVC 50 ГиБ). loadgen (60 реплик) в `app` пишет и читает Elasticsearch через Traefik кластера `elastic`. Хаос идёт по зонам `a`, `b`, `d` на обоих кластерах сразу.

**Architecture:** Общая VPC и SA `elastic-chaos-monkey`. Кластер `elastic` держит ECK, Kibana и Traefik. Кластер `app` держит loadgen, vmks и Traefik. vmagent кластера `elastic` пишет во internal NLB `vminsert` кластера `app`. Изоляция зоны — CLI (`isolate-zone.sh`/`restore-zone.sh`), не `terraform apply`.

**Tech Stack:** Terraform yandex ~> 0.220, Kubernetes 1.33, ECK 3.5.0, Elasticsearch 9.5.4, Traefik chart 41.6.0, victoria-metrics-k8s-stack 0.92.1, Chaos Mesh 2.8.4, goldpinger chart 1.1.3, Go.

**Spec:** [docs/superpowers/specs/2026-09-30-elastic-chaos-design.md](../specs/2026-09-30-elastic-chaos-design.md)

## Global Constraints

- Kubernetes 1.33 не менять. Вход — Traefik chart 41.6.0.
- Ноды k8s без публичного IP. Исключение: API master обоих кластеров — внешний endpoint (`public_ip = true`), осознанное решение для доступа с ноутбука. Egress приватных подсетей — NAT Gateway и route table.
- Загрузочные диски нод — HDD. Ноды preemptible. Исключение: PVC Elasticsearch — `yc-network-ssd`.
- Elasticsearch dedicated: master 2 vCPU / 4 ГБ, PVC 20 ГиБ, heap 1 ГиБ; data 8 vCPU / 16 ГБ, PVC 50 ГиБ, heap 3 ГиБ. Группы `elastic-master-a|b|d` (size 1) и `elastic-data-a|b|d` (size 2).
- `lifecycle.ignore_changes` на `security_group_ids` у всех девяти node group (6 elastic + 3 app).
- VictoriaMetrics только в namespace `vmks`. В values отключить scrape и recording-правила control-plane Yandex Managed K8s (etcd, scheduler, controller-manager, `kube-scheduler.rules`).
- Зону изолировать и чинить только скриптами, не `yc compute instance stop` и не `terraform apply`.
- `disable-zones` не чаще раза в 2 минуты на один NLB.
- SA остаётся `elastic-chaos-monkey`. Контексты kubectl: `elastic` и `app`. После destroy/apply контексты перезаписываются `eval "$(terraform output -raw …_credentials_command)"` — это норма.
- NetworkChaos `direction: both`.
- Шаг хаоса — 2 минуты (`STEP_SECONDS=120`). Pod-kill повторяется каждые 30 секунд всё окно шага. Между шагами — 2 минуты покоя.
- Документ 2 КБ временный: `id`, `ts`, `zone`, `body`. Состав полей переспросить после реализации.
- Коммиты — существительное, не инфинитив. Не коммитить без явного запроса пользователя.

## Имена

| Что | Имя |
|---|---|
| Кластер ES | `elastic` |
| Кластер приложения | `app` |
| Node group ES master | `elastic-master-a`, `elastic-master-b`, `elastic-master-d` |
| Node group ES data | `elastic-data-a`, `elastic-data-b`, `elastic-data-d` |
| Node group app | `app-a`, `app-b`, `app-d` |
| Контекст kubectl | `elastic`, `app` |
| Индекс | `load` |
| Deployment / chart | `loadgen`, 60 реплик |
| Namespace приложения | `load` |
| Go module | `github.com/patsevanton/elastic-chaos-monkey-mixed/loadgen` |
| Helm | `loadgen`, `traefik`, `vmks`, `elastic-operator`, `chaos-mesh`, `goldpinger` |
| Traefik `elastic` internal | `10.0.1.33` — путь loadgen → ES, не браузер |
| Traefik `app` internal | `10.0.1.34` |
| `vminsert` NLB | `10.0.1.35` |
| ES HTTP | ClusterIP `elastic-es-http` |
| Браузер | публичные IP внешних NLB: `kibana.<public elastic>.sslip.io`, `grafana.<public app>.sslip.io` |
| ES URL приложения | `http://elastic.10.0.1.33.sslip.io` |

## Состав репозитория (as-built)

Terraform: `net.tf` (три подсети `a`/`b`/`d`, NAT), `locals.tf`, `ip-dns.tf` (адреса `10.0.1.33`/`34`/`35` и два публичных), `k8s.tf` (кластер `elastic`, 6 node group), `k8s-app.tf` (кластер `app`, 3 node group), `sg.tf`, `monitoring.tf`, `*.yaml.tftpl`.

Go и chart: `loadgen/` — `go.mod`, `main.go`, `main_test.go`, `Dockerfile`, `chart/` (Deployment + Service + VMServiceScrape, `replicaCount: 60`, env `ES_URL=http://elastic.10.0.1.33.sslip.io`).

Манифесты: `manifests/eck/` (priorityclass, elasticsearch, kibana), `manifests/ingress/` (kibana через public IP, elasticsearch через internal `10.0.1.33`), `manifests/exporter/` (elasticsearch-exporter, traefik-scrape, chaos-mesh-scrape, cilium-scrape), `manifests/goldpinger/`, `manifests/vminsert/nlb.yaml`, `manifests/chaos/` (pod-kill, network-loss, network-delay — ES в ns `elastic` и loadgen в ns `load`), `manifests/chaos-mesh/rbac.yaml`.

Скрипты: `scripts/apply-eck.sh`, `scripts/isolate-zone.sh`, `scripts/restore-zone.sh`, `scripts/chaos-run.sh`, `scripts/verify-ng-isolation-sg.sh`, `scripts/annotate-grafana.sh`, `scripts/check-chaos.sh`.

Дашборды: `dashboards/cilium-node-latency.json`, `elastic-loadgen-app.json`, `elasticsearch-cluster.json`, `goldpinger.json`.

## Порядок установки с нуля (автономный)

Требования: yc CLI, Terraform >= 1.3, kubectl, Helm >= 3, `jq`, `curl`, `envsubst`.

1. **Terraform.** `export TF_VAR_folder_id=<folder id>`; `terraform init && terraform apply`. Если стенд уже стоит — `No changes`.
2. **kubeconfig.** `eval "$(terraform output -raw elastic_credentials_command)"` и `eval "$(terraform output -raw app_credentials_command)"`. После destroy/apply контексты всегда перезаписывать — старые endpoint'ы мертвы.
3. **Helm-репозитории.** `helm repo add elastic https://helm.elastic.co`, `chaos-mesh https://charts.chaos-mesh.org`, `goldpinger https://bloomberg.github.io/goldpinger`, затем `helm repo update`. Traefik и vmks тянутся по OCI, `helm repo add` им не нужен.
4. **Traefik 41.6.0** в оба контекста: `-f traefik-elastic-values.yaml` в `elastic`, `-f traefik-app-values.yaml` в `app`.
5. **vmks 0.92.1** — см. [AGENTS.md](../../../AGENTS.md) «Установка VictoriaMetrics»: в `app` сначала namespace, `manifests/chaos-mesh/rbac.yaml` и ожидание secret `chaos-mesh-admin-token`, затем `helm -f vmks-values.yaml`; в `elastic` — `helm -f vmks-elastic-values.yaml`. После — `manifests/exporter/traefik-scrape.yaml` и internal NLB `vminsert` (`NLB_SUBNET_ID="$(terraform output -raw nlb_subnet_id)" envsubst < manifests/vminsert/nlb.yaml | kubectl --context app apply -f -`).
6. **ECK 3.5.0** в `elastic`: `helm --kube-context elastic upgrade --install elastic-operator elastic/eck-operator --namespace elastic-system --create-namespace --version 3.5.0 --set replicaCount=3`, затем `./scripts/apply-eck.sh` и `kubectl --context elastic apply -f manifests/exporter/elasticsearch-exporter.yaml`.
7. **Chaos Mesh 2.8.4** в оба контекста (`-f chaos-mesh-elastic-values.yaml`, `-f chaos-mesh-app-values.yaml`), затем `kubectl --context app apply -f manifests/exporter/chaos-mesh-scrape.yaml`.
8. **goldpinger 1.1.3** в оба контекста (`-f goldpinger-values.yaml`), затем в обоих: `manifests/goldpinger/goldpinger-scrape.yaml` и `manifests/exporter/cilium-scrape.yaml`.
9. **loadgen** в `app`: `helm --kube-context app upgrade --install loadgen loadgen/chart --namespace load --create-namespace`. Образ — `ghcr.io/patsevanton/elastic-chaos-monkey-mixed`, тег в `loadgen/chart/values.yaml`, собирается workflow `.github/workflows/docker.yml`.

### Проверка после установки

- Поды обоих кластеров: нет вне `Running`/`Completed`.
- ES: `kubectl --context elastic -n elastic get elasticsearch elastic` — `HEALTH green`, 9 нод. Kibana — green.
- Индекс: `kubectl --context elastic -n elastic exec elastic-es-master-a-0 -- curl -s 'localhost:9200/load/_settings?pretty'` — 1 primary / 2 replica.
- loadgen: 60/60 Ready; логи `kubectl --context app -n load logs -l app=loadgen` — без `ensureIndex: … retry`.
- Коннект до публичных IP из `terraform output public_ips_csv`: внешние NLB отвечают (404 на корне — норма), API master — `https://<ip>:443/healthz` = 200; Ingress kibana/grafana — 302, chaos-dashboard — 200.

## Прогон

Перед первым прогоном на кластере — для каждой изолируемой node group в её контексте:

```bash
./scripts/verify-ng-isolation-sg.sh "$(terraform output -raw zone_isolation_sg_id)" <zone> <node-group>
```

Группы: `elastic-master-a|b|d`, `elastic-data-a|b|d` — контекст `elastic`; `app-a|b|d` — контекст `app`.

- `VERDICT: HOT-REPLACE` — `node-group update` меняет SG на живой VM, isolate/restore работают как есть.
- `VERDICT: RECREATE` — managed k8s пересоздаёт узел. **Остановиться**, isolate/restore не использовать, записать факт в отчёт и предложить варианты: A — переписать isolate/restore на `yc compute instance update-network-interface`; B — пропустить шаг изоляции, прогнав pod-kill/loss/delay. Автономно ни один вариант не применять.

```bash
./scripts/chaos-run.sh
```

Порядок зон: `a`, `b`, `d`. На зону: 2 минуты pod-kill (каждые 30 с), 2 минуты покой, 2 минуты loss 30% (`direction: both`), покой, 2 минуты delay 500 мс, покой, 2 минуты изоляция, restore, покой. Проверка потери данных — после каждого шага, не только в конце: `_count` только растёт, успешный bulk виден в `mget`.

Стоп: Ctrl-C в `chaos-run.sh` снимает Chaos CR и вызывает restore, если зона изолирована. Вручную: остановить loadgen, `./scripts/restore-zone.sh`, удалить Chaos CR. Не `terraform apply` и не power-off.

## Review Focus

- Изоляция одной зоны должна сменить SG трёх node group этой зоны (`elastic-master-*`, `elastic-data-*`, `app-*`), не соседних зон и не второго кластера.
- `terraform apply` во время изоляции не должен вернуть SG: `ignore_changes` на всех девяти node group.
- Pod-kill не должен убить поды вне зоны шага.
- После restore оба NLB (`traefik` elastic и `vminsert`) снова принимают зону.
- Успешный bulk, принятый до сбоя, находится `_count` и `mget`.
- Master-nodeSet с `volumeClaimTemplates` (PVC 20 ГиБ) — по контракту master с PVC, не без PVC. Проверка — `volumeClaimTemplates` есть у всех шести nodeSet.
- Data с `node.roles: ["data", "ingest"]`: проверка — роли в манифесте.
- Старый state `.state/zone-isolate.env` с ключами `ELASTIC_NG`/`ELASTIC_SG` после смены имён: restore должен отказаться, а не повесить SG не на ту группу.
