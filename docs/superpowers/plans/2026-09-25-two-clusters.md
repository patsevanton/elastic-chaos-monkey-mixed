# Два кластера: реализация

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Стенд из двух кластеров `elastic` и `app`: Go-нагрузка пишет и читает Elasticsearch, хаос идёт по зонам `a`, `b`, `d` на обоих кластерах сразу.

**Architecture:** Общая VPC и SA `elastic-chaos-monkey`. Кластер `elastic` держит ECK, Kibana и Traefik. Кластер `app` держит loadgen, vmks и Traefik. vmagent кластера `elastic` пишет в internal NLB `vminsert`. Изоляция зоны — CLI, не `terraform apply`.

**Tech Stack:** Terraform yandex ~> 0.220, Kubernetes 1.33, ECK 3.5.0, Elasticsearch 9.5.4, Traefik chart 41.6.0, victoria-metrics-k8s-stack 0.92.1, Chaos Mesh 2.8.4, Go.

**Spec:** [docs/superpowers/specs/2026-09-24-elastic-chaos-two-clusters-design.md](../specs/2026-09-24-elastic-chaos-two-clusters-design.md)

## Global Constraints

- Kubernetes 1.33 не менять. Вход — Traefik chart 41.6.0.
- Ноды k8s без публичного IP. Egress приватных подсетей — один NAT Gateway и route table.
- Загрузочные диски нод — HDD. Ноды preemptible.
- PVC Elasticsearch — `yc-network-ssd` 50 ГиБ. Это исключение из правила HDD. Вход — Traefik.
- VictoriaMetrics только в namespace `vmks`. В values отключить scrape и recording-правила control-plane Yandex Managed K8s (etcd, scheduler, controller-manager, `kube-scheduler.rules`).
- Зону изолировать и чинить только скриптами, не `yc compute instance stop` и не `terraform apply`.
- `disable-zones` не чаще раза в 2 минуты на один NLB.
- SA остаётся `elastic-chaos-monkey`.
- Контексты kubectl: `elastic` и `app`.
- NetworkChaos `direction: both`.
- Pod-kill повторяется каждые 30 секунд все 10 минут шага.
- Документ 2 КБ временный: `id`, `ts`, `zone`, `body`. Состав полей переспросить после реализации.
- Цифры результатов в README — плейсхолдеры.

## Имена

| Что | Имя |
|---|---|
| Кластер ES | `elastic` |
| Кластер приложения | `app` |
| Node group ES | `elastic-a`, `elastic-b`, `elastic-d` |
| Node group app | `app-a`, `app-b`, `app-d` |
| Контекст kubectl | `elastic`, `app` |
| Индекс | `load` |
| Deployment / chart | `loadgen` |
| Namespace приложения | `load` |
| Go module | `github.com/patsevanton/elastic-chaos-monkey-mixed/loadgen` |
| Helm | `loadgen`, `traefik`, `vmks`, `vmagent`, `elastic-operator` |
| Traefik `elastic` | `10.0.1.33` |
| Traefik `app` | `10.0.1.34` |
| `vminsert` NLB | `10.0.1.35` |
| ES HTTP | ClusterIP `elastic-es-http` |
| Хосты | `kibana.10.0.1.33.sslip.io`, `grafana.10.0.1.34.sslip.io` |
| ES URL приложения | `http://elastic.10.0.1.33.sslip.io` |

## Review Focus

- Изоляция одной зоны не должна сменить SG соседней зоны или второго кластера не в этой зоне.
- `terraform apply` во время изоляции не должен вернуть SG: `ignore_changes` на всех шести node group.
- Pod-kill не должен убить поды вне зоны шага.
- После restore оба NLB (`traefik` elastic и `vminsert`) снова принимают зону.
- Успешный bulk, принятый до сбоя, находится `_count` и `mget`.

## File structure

Создать:

- `k8s-app.tf` — кластер `app`, ноды 2 vCPU / 4 ГБ
- `loadgen/` — Go-модуль и Helm chart
- `manifests/vmagent/vmagent.yaml` — remote write в `10.0.1.35`
- `manifests/vminsert/nlb.yaml` — internal NLB на vminsert
- `manifests/ingress/elasticsearch.yaml` — Ingress Traefik кластера `elastic`
- `scripts/isolate-zone.sh`, `scripts/restore-zone.sh`, `scripts/chaos-run.sh`
- `scripts/loadgen_test.go` не создавать: тесты лежат в `loadgen/`

Изменить:

- `k8s.tf` — переименовать кластер и node group, `ignore_changes` на SG всех групп `elastic`
- `ip-dns.tf` — убрать `es_nlb`, добавить `10.0.1.34` и `10.0.1.35`
- `locals.tf`, `net.tf` — убрать подсеть `e`
- `monitoring.tf` и `*.tftpl` — два Traefik, Grafana на IP app
- `manifests/eck/elasticsearch.yaml` — ClusterIP, имя `elastic`
- `manifests/chaos/*.yaml` — зона параметром, `direction: both`, pod-kill на окно
- `scripts/verify-ng-sg-swap.sh` — аргументы zone и node group, контекст kubectl
- `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`
- `.opencode/agents/chaos-check.md`, `.opencode/agents/script-runner.md`

Удалить:

- `rally-vm.tf`, `cloud-init/rally.yaml`
- `scripts/chaos-loop.sh`

---

### Task 1: Сеть без подсети `e`, адреса NLB

**Files:**
- Modify: `net.tf`, `locals.tf`, `ip-dns.tf`
- Test: `terraform validate`

**Interfaces:**
- Produces: `local.traefik_elastic_ip` = `10.0.1.33`, `local.traefik_app_ip` = `10.0.1.34`, `local.vminsert_ip` = `10.0.1.35`
- Consumes: ничего

- [ ] **Step 1: Удалить подсеть `e`**

В `net.tf` удалить ресурс `yandex_vpc_subnet.elastic_chaos_e`.
В `locals.tf` удалить `subnet_e_id` и `subnet_e_zone`.

- [ ] **Step 2: Заменить reserved IP**

В `ip-dns.tf` удалить `yandex_vpc_address.es_nlb`.
Ресурс `yandex_vpc_address.traefik` оставить на `10.0.1.33`, имя `elastic-traefik-internal`.
Добавить `yandex_vpc_address.traefik_app` на `10.0.1.34`, имя `app-traefik-internal`.
Добавить `yandex_vpc_address.vminsert` на `10.0.1.35`, имя `app-vminsert-internal`.
Оба — `internal_ipv4_address.subnet_id` = подсеть `a`.
В `time_sleep.wait_lb_release.depends_on` заменить `es_nlb` на `traefik_app` и `vminsert`.

- [ ] **Step 3: Locals IP**

```hcl
traefik_elastic_ip = yandex_vpc_address.traefik.internal_ipv4_address[0].address
traefik_app_ip     = yandex_vpc_address.traefik_app.internal_ipv4_address[0].address
vminsert_ip        = yandex_vpc_address.vminsert.internal_ipv4_address[0].address
```

`traefik_ip` удалить. Все ссылки на `local.traefik_ip` в этой задаче не трогать — их закроет Task 4.

- [ ] **Step 4: Проверка**

Run: `terraform validate`
Expected: Success. `terraform plan` не запускать без явной просьбы: план удалит Rally VM и подсеть `e`.

---

### Task 2: Кластер `elastic`

**Files:**
- Modify: `k8s.tf`

**Interfaces:**
- Produces: output `elastic_credentials_command`, node group names `elastic-a|b|d`
- Consumes: `local.network_id`, subnet ids

- [ ] **Step 1: Переименовать кластер**

`yandex_kubernetes_cluster.elastic_chaos`: `name = "elastic"`.
Три node group: `name` = `elastic-a`, `elastic-b`, `elastic-d`. Размер 8 vCPU / 16 ГБ, `network-hdd`, `nat = false`, preemptible, version `1.33`, `public_ip = false` не менять.

- [ ] **Step 2: ignore_changes на всех трёх группах**

На `k8s_node_group_a` и `k8s_node_group_d` добавить тот же блок, что уже есть у `b`:

```hcl
lifecycle {
  ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
}
```

- [ ] **Step 3: Outputs**

Заменить `k8s_cluster_credentials_command` на:

```hcl
output "elastic_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.elastic_chaos.id} --internal --force --context-name elastic"
}
```

`k8s_cluster_id` оставить как id кластера `elastic`. Описание `zone_isolation_sg_id` без «зоны b». Output `nlb_subnet_id` оставить: это подсеть `a` для internal NLB.

- [ ] **Step 4: Проверка**

Run: `terraform validate`
Expected: Success.

Переименование кластера в Yandex — смена ресурса с новым id, если name меняется у существующего state. Перед apply спросить: state move или новый кластер. В этой задаче apply не делать.

---

### Task 3: Кластер `app`

**Files:**
- Create: `k8s-app.tf`

**Interfaces:**
- Produces: `yandex_kubernetes_cluster.app`, output `app_credentials_command`
- Consumes: тот же SA `yandex_iam_service_account.elastic_chaos_monkey`, те же subnet ids

- [ ] **Step 1: Кластер**

Скопировать структуру master из `k8s.tf`: regional `ru-central1`, три location a/b/d, `version = "1.33"`, `public_ip = false`, `release_channel = "STABLE"`, оба SA id = `elastic-chaos-monkey`.
`name = "app"`.
`depends_on` = `[time_sleep.wait_sa, time_sleep.wait_lb_release]`.

- [ ] **Step 2: Три node group**

`app-a`, `app-b`, `app-d`. `cores = 2`, `memory = 4`, boot `network-hdd` size 64, `nat = false`, preemptible, version `1.33`, fixed scale 1.
У каждой:

```hcl
lifecycle {
  ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
}
```

- [ ] **Step 3: Output**

```hcl
output "app_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.app.id} --internal --force --context-name app"
}
```

- [ ] **Step 4: Проверка**

Run: `terraform validate`
Expected: Success.

---

### Task 4: Values Traefik и Grafana

**Files:**
- Modify: `monitoring.tf`, `traefik-values.yaml.tftpl`, `vmks-values.yaml.tftpl`, `chaos-mesh-values.yaml.tftpl`

**Interfaces:**
- Consumes: `local.traefik_elastic_ip`, `local.traefik_app_ip`, `local.subnet_a_id`
- Produces: `traefik-elastic-values.yaml`, `traefik-app-values.yaml`, `vmks-values.yaml` (Grafana host на IP app)

- [ ] **Step 1: Два файла Traefik**

`monitoring.tf` рендерит два `local_file`: `traefik-elastic-values.yaml` (IP `10.0.1.33`) и `traefik-app-values.yaml` (IP `10.0.1.34`). Шаблон тот же: replicas 3, internal LB, `loadBalancerIP`, subnet annotation. Старый `traefik-values.yaml` больше не писать.

- [ ] **Step 2: vmks на IP app**

В `vmks-values.yaml.tftpl` ingress Grafana: host `grafana.${ingress_ip}.sslip.io`, куда `ingress_ip` = `local.traefik_app_ip`.
Control-plane disable не трогать.
vminsert оставить в кластере; NLB — отдельный манифест Task 7, не в этом values.

- [ ] **Step 3: Chaos Mesh dashboard**

`chaos-mesh-values.yaml.tftpl`: два рендера не делать. Dashboard ingress кластера `elastic` — host `chaos-dashboard.10.0.1.33.sslip.io`. Для `app` тот же шаблон с `10.0.1.34`, файл `chaos-mesh-app-values.yaml`. Контроллер `replicaCount: 3` не менять.

- [ ] **Step 4: Outputs**

`grafana_url` = `http://grafana.<публичный IP Traefik app>.sslip.io` через `local.traefik_app_public_ip`. Не internal `10.0.1.34`.
`kibana_url` = `http://kibana.10.0.1.33.sslip.io`.
Удалить output `es_nlb_ip`.
`kibana_elastic_password_command`: secret `elastic-es-elastic-user`.

- [ ] **Step 5: Проверка**

Run: `terraform validate`
Expected: Success. Содержимое yaml сверить с IP после следующего apply, не в этой задаче.

---

### Task 5: Elasticsearch ClusterIP и Ingress

**Files:**
- Modify: `manifests/eck/elasticsearch.yaml`, `manifests/eck/kibana.yaml`, `manifests/ingress/kibana.yaml`, `scripts/apply-eck.sh`
- Create: `manifests/ingress/elasticsearch.yaml`

**Interfaces:**
- Produces: Service `elastic-es-http` ClusterIP, Ingress host `elastic.10.0.1.33.sslip.io` → `:9200`
- Consumes: Traefik кластера `elastic`

- [ ] **Step 1: CR Elasticsearch**

`metadata.name: elastic` (было `chaos`). Namespace `elastic` оставить.
Удалить блок `http.service` с LoadBalancer, annotations и `loadBalancerIP`. Без этого блока ECK создаёт ClusterIP.
`node.roles`, awareness, heap `-Xms3g -Xmx3g`, CPU request 4 / limit 6, memory request 6Gi, PVC `50Gi` `yc-network-ssd`.
Memory limit 6Gi оставить как есть: спека лимит памяти не задаёт, выдумывать новый нельзя.
Анонимный superuser оставить: HTTP без пароля.

- [ ] **Step 2: Kibana и Ingress**

В `kibana.yaml` `elasticsearchRef.name: elastic`.
В `ingress/kibana.yaml` host `kibana.10.0.1.33.sslip.io`, backend Service имени, которое ECK даёт Kibana от CR `elastic` (сейчас `chaos-kb-http` — заменить на имя от CR `elastic`, сверить с `kubectl get svc` после apply; в манифесте не хардкодить старое `chaos-kb-http`).
Новый `manifests/ingress/elasticsearch.yaml`: Ingress class `traefik`, host `elastic.10.0.1.33.sslip.io`, backend `elastic-es-http:9200`, namespace `elastic`.

- [ ] **Step 3: apply-eck.sh**

Убрать подстановку `ES_NLB_IP`. `INGRESS_IP` для Kibana и ES Ingress = terraform output IP Traefik elastic (`10.0.1.33`). `NLB_SUBNET_ID` из ES-манифеста больше не нужен.

- [ ] **Step 4: Exporter**

В `manifests/exporter/elasticsearch-exporter.yaml` URI `http://elastic-es-http.elastic.svc:9200`. Реплики 3 и spread не менять.

---

### Task 6: Go loadgen

**Files:**
- Create: `loadgen/go.mod`, `loadgen/main.go`, `loadgen/main_test.go`, `loadgen/Dockerfile`

**Interfaces:**
- Produces: процесс с флагами `-es` (URL), метрики Prometheus `:8080`: `loadgen_bulk_ok_total`, `loadgen_bulk_err_total`, `loadgen_search_ok_total`, `loadgen_search_err_total`
- Consumes: ES HTTP без TLS и без пароля

Документ, пока не переспросили поля: JSON `{"id":"<uuid>","ts":"<RFC3339>","zone":"<hostname zone or empty>","body":"<padding>"}`. Сериализованный размер 2048 байт. Индекс `load`, mapping при старте: 1 primary, 2 replica. Не geo.

- [ ] **Step 1: Падающий тест размера**

```go
func TestDocSize(t *testing.T) {
    b := doc("id-1", time.Unix(0, 0).UTC(), "")
    if len(b) != 2048 {
        t.Fatalf("size %d", len(b))
    }
}
```

Run: `cd loadgen && go test -count=1 .`
Expected: FAIL, `doc` не определён.

- [ ] **Step 2: Реализация doc**

`body` добивает JSON до 2048 байт. Если поля длиннее 2048 — panic в тесте, не обрезать молча.

- [ ] **Step 3: Тест проходит**

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.

- [ ] **Step 4: Две горутины**

`main`: горутина bulk и горутина search с первой секунды. Bulk `_bulk` в индекс `load`, id из документа. Search — `match_all` size 1. Ошибки HTTP и item-level bulk увеличивают `*_err_total`. Успешный bulk увеличивает `bulk_ok_total` и пишет id в stdout одной строкой `id <uuid>` для `mget`.

- [ ] **Step 5: Тест счётчика**

Тест с `httptest.Server`: один успешный bulk item даёт `bulk_ok_total == 1`. Один ответ 500 даёт `bulk_err_total == 1`.

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.

---

### Task 7: Chart loadgen, vminsert NLB, vmagent

**Files:**
- Create: `loadgen/chart/`, `manifests/vminsert/nlb.yaml`, `manifests/vmagent/vmagent.yaml`

**Interfaces:**
- Consumes: `loadgen` image, `local.vminsert_ip`, ES Ingress URL
- Produces: Deployment 3 реплики, spread `maxSkew: 1`, env `ES_URL`

- [ ] **Step 1: Chart**

Deployment `loadgen`, namespace `load`, replicas 3.
`topologySpreadConstraints`: `maxSkew: 1`, `topologyKey: topology.kubernetes.io/zone`, `whenUnsatisfiable: DoNotSchedule`. Affinity зоны `b` нет.
Env `ES_URL=http://elastic.10.0.1.33.sslip.io`.
Service port 8080 для scrape. Без публичного Service.

- [ ] **Step 2: vminsert NLB**

Service в namespace `vmks`, selector лейблов vminsert из чарта vmks 0.92.1 (сверить `kubectl -n vmks get pod -l app.kubernetes.io/name=vminsert --show-labels` после установки; не выдумывать лейбл, если установка ещё не сделана — в манифесте оставить комментарий с командой сверки и лейбл, который печатает `helm template` victoria-metrics-k8s-stack 0.92.1).
Type LoadBalancer, annotations internal, subnet `a`, `loadBalancerIP: 10.0.1.35`, port remote write vminsert (порт из values чарта, не выдумывать: взять из `helm template` 0.92.1).

- [ ] **Step 3: vmagent в кластере elastic**

Один манифест: vmagent scrape `elasticsearch-exporter` и remote write на `http://10.0.1.35:<port>/insert/0/prometheus`. Не remote write в vmagent кластера `app`.
Отдельный helm vmks в кластере `elastic` не ставить.

- [ ] **Step 4: VMServiceScrape приложения**

В чарте loadgen — `VMServiceScrape` namespace `load`, порт метрик. Ставится в кластер `app`, где живёт vmagent vmks.

---

### Task 8: Скрипты изоляции любой зоны

**Files:**
- Create: `scripts/isolate-zone.sh`, `scripts/restore-zone.sh`
- Modify: `scripts/verify-ng-sg-swap.sh`
- Delete: не удалять `isolate-zone-b.sh` в этой задаче — его заменит вызов нового скрипта, удаление в Task 10

**Interfaces:**
- Consumes: контексты `elastic` и `app`, output `zone_isolation_sg_id`
- Produces: `./scripts/isolate-zone.sh ru-central1-a|b|d`, state `.state/zone-isolate.env`

- [ ] **Step 1: isolate-zone.sh**

Аргумент — зона `ru-central1-a|b|d`. Суффикс node group — последняя буква (`a|b|d`).
Для контекста `elastic` node group `elastic-<suffix>`. Для контекста `app` — `app-<suffix>`.
Сохранить текущие SG обоих node group.
Пустой SG на оба node group. VM не останавливать.
`disable-zones` этой зоны на NLB Traefik контекста `elastic` и на NLB `vminsert` (Service в `vmks`, IP `10.0.1.35`). На кластере `app` `disable-zones` нет.
Между двумя `disable-zones` пауза 120 секунд: лимит «не чаще раза в 2 минуты» в спеке на один NLB; пауза всё равно нужна, если оператор повторяет шаг. Если id разные, паузу всё равно держать 120 секунд — так проще не нарушить лимит при retry.
State: зона, оба NG, оба списка SG, оба NLB id.

- [ ] **Step 2: restore-zone.sh**

Читает state. Возвращает SG обоим node group. `enable-zones` на оба NLB из state. Удаляет state. Не вызывает terraform.

- [ ] **Step 3: verify-ng-sg-swap.sh**

Аргументы: `<isolation-sg-id> <zone> <node-group>`. Контекст kubectl — текущий, вызывающий передаёт его сам (`kubectl config use-context`).
`VERDICT: HOT-SWAP` или `VERDICT: RECREATE` сохранить. Текст больше не ссылается только на `isolate-zone-b.sh`.

- [ ] **Step 4: Проверка синтаксиса**

Run: `bash -n scripts/isolate-zone.sh && bash -n scripts/restore-zone.sh && bash -n scripts/verify-ng-sg-swap.sh`
Expected: пустой вывод, код 0.

На живом кластере не запускать в этой задаче.

---

### Task 9: Chaos CR и прогон

**Files:**
- Modify: `manifests/chaos/pod-kill.yaml`, `network-loss.yaml`, `network-delay.yaml`
- Create: `scripts/chaos-run.sh`, `manifests/chaos/pod-kill-loadgen.yaml`, `network-loss-loadgen.yaml`, `network-delay-loadgen.yaml`

**Interfaces:**
- Consumes: контексты, `isolate-zone.sh` / `restore-zone.sh`
- Produces: `./scripts/chaos-run.sh` — зоны a, b, d по очереди

- [ ] **Step 1: CR Elasticsearch**

Селектор `elasticsearch.k8s.elastic.co/cluster-name: elastic`.
`network-loss.yaml`: loss `30`, `direction: both`, `mode: all`, duration `10m`.
`network-delay.yaml`: latency `500ms`, `direction: both`, duration `10m`.
Зона в yaml — плейсхолдер `ZONE`, скрипт подставляет `ru-central1-a|b|d`.
`pod-kill.yaml`: `mode: all`, selector по зоне через `nodeSelectors`, duration не ограничивает окно: окно держит скрипт.

- [ ] **Step 2: CR loadgen**

Те же три вида в namespace `load`, selector `app: loadgen`, `nodeSelectors` зоны. `direction: both` на network. Применять в контексте `app`.

- [ ] **Step 3: chaos-run.sh**

Порядок зон: `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.
На каждую зону, оба контекста одновременно:

1. 10 минут pod-kill: цикл `kubectl apply` / sleep 30 / пока не истечёт 600 секунд, в обоих контекстах.
2. 10 минут покоя: удалить CR, ждать ES green и loadgen Ready, остаток до 600 секунд спать.
3. 10 минут network loss, оба кластера.
4. 10 минут покоя.
5. 10 минут network delay.
6. 10 минут покоя.
7. 10 минут `./scripts/isolate-zone.sh <zone>`.
8. `./scripts/restore-zone.sh`, ждать green и Ready, затем 10 минут покоя.

Пока зона изолирована, green не ждать.
После каждого шага печатать: `loadgen_bulk_ok_total` против `GET /load/_count`, выборка id из stdout пода и `_mget`, проценты ошибок bulk и search. Порога нет.
Стоп по Ctrl-C: удалить Chaos CR в обоих контекстах, вызвать `restore-zone.sh` если state есть.

- [ ] **Step 4: Синтаксис**

Run: `bash -n scripts/chaos-run.sh`
Expected: код 0.

---

### Task 10: Документы, агенты, удаление Rally

**Files:**
- Delete: `rally-vm.tf`, `cloud-init/rally.yaml`, `scripts/chaos-loop.sh`, `scripts/isolate-zone-b.sh`, `scripts/restore-zone-b.sh`
- Modify: `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`, `.opencode/agents/chaos-check.md`, `.opencode/agents/script-runner.md`

- [ ] **Step 1: Удалить Rally**

Удалить файлы из списка. В `scripts/check-count.sh` и `sample-mget.sh` индекс по умолчанию `load`.

- [ ] **Step 2: AGENTS.md**

Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`.
`verify-ng-sg-swap.sh` вызывать для каждой node group, которую будут изолировать, с контекстом этого кластера. При `VERDICT: RECREATE` isolate/restore не использовать.

- [ ] **Step 3: INFRASTRUCTURE.md**

Два кластера, ноды, IP `10.0.1.33/34/35`. Изоляция: SG на node group зоны в обоих кластерах, `disable-zones` только NLB Traefik `elastic` и NLB `vminsert`. Восстановление возвращает SG и делает `enable-zones` на оба NLB.

- [ ] **Step 4: README**

Статья по спеке: путь app → Traefik `elastic` → ES, четыре шага по трём зонам, критерии без порога. Таблица результатов — плейсхолдеры. Команды helm: Traefik в оба контекста, vmks только в `app`, ECK и exporter только в `elastic`, Chaos Mesh в оба, chart loadgen в `app`.

- [ ] **Step 5: Агенты**

`script-runner`: esrally убрать. Запуск `chaos-run.sh`, `isolate-zone.sh`, `restore-zone.sh`.
`chaos-check`: не только зона `b`. NLB — Traefik `elastic` и `vminsert`, не `chaos-es-http`.

- [ ] **Step 6: Поиск Rally**

Run: `rg -n 'rally|esrally|10\.0\.4\.0/24|chaos-es-http|isolate-zone-b' --glob '!docs/superpowers/specs/2026-09-18*' --glob '!docs/superpowers/plans/2026-09-19*'`
Expected: совпадений в коде и актуальных документах нет. Старые спеки не переписывать.

---

### Task 11: Тесты Review Focus

**Files:**
- Create: `loadgen/loss_test.go`
- Modify: `scripts/chaos-run.sh` только если тест скрипта нужен; логику зон не дублировать в Go

- [ ] **Step 1: Тест «bulk до сбоя виден в mget»**

`httptest`: приложение (функция bulk, не весь main) пишет документ, сервер сохраняет id, `mget` по этому id возвращает found. Это закрывает критерий «нет потери принятого bulk» на уровне клиента: клиент не считает успехом ответ без `created`/`ok`.

- [ ] **Step 2: Проверка селектора зоны**

В `manifests/chaos/pod-kill.yaml` после подстановки `ZONE=ru-central1-a` нет `ru-central1-b` и `ru-central1-d`.
Run: `ZONE=ru-central1-a envsubst < manifests/chaos/pod-kill.yaml | grep -c ru-central1-a`
Expected: 1. `grep ru-central1-b` — код 1.

- [ ] **Step 3: go test**

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.
