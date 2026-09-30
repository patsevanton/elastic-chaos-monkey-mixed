# Отказоустойчивость Elasticsearch: два кластера — план реализации

> Стенд уже собран. Задачи ниже — контракт того, что есть, не инструкция пересоздать его. Не делать `terraform apply` и не применять манифест ECK заново: это снесёт dedicated-ноды и PVC, не mixed. Хаос — только `./scripts/isolate-zone.sh` / `./scripts/restore-zone.sh` / `./scripts/chaos-run.sh`.

**Goal:** Стенд из двух кластеров `elastic` и `app` уже работает. В кластере `elastic` — Elasticsearch dedicated master (3, PVC 20 ГиБ) + data (6, PVC 50 ГиБ). loadgen (60 реплик) пишет и читает Elasticsearch, хаос идёт по зонам `a`, `b`, `d` на обоих кластерах сразу.

**Architecture:** Общая VPC и SA `elastic-chaos-monkey`. Кластер `elastic` держит ECK, Kibana и Traefik. Кластер `app` держит loadgen, vmks и Traefik. vmagent кластера `elastic` пишет в internal NLB `vminsert`. Изоляция зоны — CLI (`isolate-zone.sh`/`restore-zone.sh`), не `terraform apply`.

**Tech Stack:** Terraform yandex ~> 0.220, Kubernetes 1.33, ECK 3.5.0, Elasticsearch 9.5.4, Traefik chart 41.6.0, victoria-metrics-k8s-stack 0.92.1, Chaos Mesh 2.8.4, Go.

**Spec:** [docs/superpowers/specs/2026-09-30-elastic-chaos-design.md](../specs/2026-09-30-elastic-chaos-design.md)

## Global Constraints

- Kubernetes 1.33 не менять. Вход — Traefik chart 41.6.0.
- Ноды k8s без публичного IP. Egress приватных подсетей — один NAT Gateway и route table. API master обоих кластеров — внешний (`public_ip = true`).
- Загрузочные диски нод — HDD. Ноды preemptible. Исключение: PVC Elasticsearch — `yc-network-ssd`.
- Elasticsearch dedicated: master 2 vCPU / 4 ГБ, PVC 20 ГиБ, heap 1 ГиБ; data 8 vCPU / 16 ГБ, PVC 50 ГиБ, heap 3 ГиБ. Группы `elastic-a|b|d` удалить, вместо них `elastic-master-a|b|d` и `elastic-data-a|b|d`.
- `lifecycle.ignore_changes` на `security_group_ids` у всех девяти node group (6 elastic + 3 app).
- VictoriaMetrics только в namespace `vmks`. В values отключить scrape и recording-правила control-plane Yandex Managed K8s (etcd, scheduler, controller-manager, `kube-scheduler.rules`).
- Зону изолировать и чинить только скриптами, не `yc compute instance stop` и не `terraform apply`.
- `disable-zones` не чаще раза в 2 минуты на один NLB.
- SA остаётся `elastic-chaos-monkey`. Контексты kubectl: `elastic` и `app`.
- NetworkChaos `direction: both`.
- Шаг хаоса — 2 минуты (`STEP_SECONDS=120`). Pod-kill повторяется каждые 30 секунд всё окно шага. Между шагами — 2 минуты покоя.
- Документ 2 КБ временный: `id`, `ts`, `zone`, `body`. Состав полей переспросить после реализации.
- Цифры результатов в README — плейсхолдеры.
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
| Helm | `loadgen`, `traefik`, `vmks`, `elastic-operator` |
| Traefik `elastic` internal | `10.0.1.33` — путь loadgen → ES, не браузер |
| Traefik `app` internal | `10.0.1.34` |
| `vminsert` NLB | `10.0.1.35` |
| ES HTTP | ClusterIP `elastic-es-http` |
| Браузер | публичные IP внешних NLB: `kibana.<public elastic>.sslip.io`, `grafana.<public app>.sslip.io` |
| ES URL приложения | `http://elastic.10.0.1.33.sslip.io` |

## Review Focus

- Изоляция одной зоны должна сменить SG трёх node group этой зоны (`elastic-master-*`, `elastic-data-*`, `app-*`), не соседних зон и не второго кластера.
- `terraform apply` во время изоляции не должен вернуть SG: `ignore_changes` на всех девяти node group.
- Pod-kill не должен убить поды вне зоны шага.
- После restore оба NLB (`traefik` elastic и `vminsert`) снова принимают зону.
- Успешный bulk, принятый до сбоя, находится `_count` и `mget`.
- Master-nodeSet с `volumeClaimTemplates` (PVC 20 ГиБ) — по контракту master с PVC, не без PVC. Проверка — `volumeClaimTemplates` есть у всех шести nodeSet.
- Data без `node.roles: ["data", "ingest"]`: шарды некуда положить. Проверка — роли в манифесте.
- Старый state `.state/zone-isolate.env` с ключами `ELASTIC_NG`/`ELASTIC_SG` после смены имён: restore должен отказаться, а не повесить SG не на ту группу.

## File structure

Создать:

- `k8s-app.tf` — кластер `app`, ноды 4 vCPU / 8 ГБ
- `loadgen/` — Go-модуль и Helm chart
- remote write vmagent `elastic` — в `vmks-elastic-values.yaml`
- `manifests/vminsert/nlb.yaml` — internal NLB на vminsert
- `manifests/ingress/elasticsearch.yaml` — Ingress Traefik кластера `elastic`
- `scripts/isolate-zone.sh`, `scripts/restore-zone.sh`, `scripts/chaos-run.sh`

Изменить:

- `k8s.tf` — кластер `elastic`, шесть node group (master/data), `ignore_changes` на SG
- `ip-dns.tf` — `10.0.1.33`, `10.0.1.34`, `10.0.1.35`
- `locals.tf`, `net.tf` — убрать подсеть `e`
- `monitoring.tf` и `*.tftpl` — два Traefik, Grafana на IP app
- `manifests/eck/elasticsearch.yaml` — имя `elastic`, шесть nodeSet (master 20 ГиБ PVC, data 50 ГиБ PVC)
- `manifests/chaos/*.yaml` — зона параметром, `direction: both`, pod-kill на окно
- `scripts/verify-ng-isolation-sg.sh` — аргументы zone и node group, контекст kubectl
- `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`
- `.opencode/agents/chaos-check.md`, `.opencode/agents/script-runner.md`

Удалить:

- `rally-vm.tf`, `cloud-init/rally.yaml`
- `scripts/chaos-loop.sh`, `scripts/isolate-zone-b.sh`, `scripts/restore-zone-b.sh`

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
Ресурс `yandex_vpc_address.traefik` — `10.0.1.33`, имя `elastic-traefik-internal`.
Добавить `yandex_vpc_address.traefik_app` — `10.0.1.34`, имя `app-traefik-internal`.
Добавить `yandex_vpc_address.vminsert` — `10.0.1.35`, имя `app-vminsert-internal`.
Оба — `internal_ipv4_address.subnet_id` = подсеть `a`.
В `time_sleep.wait_lb_release.depends_on` заменить `es_nlb` на `traefik_app` и `vminsert`.

- [ ] **Step 3: Locals IP**

```hcl
traefik_elastic_ip = yandex_vpc_address.traefik.internal_ipv4_address[0].address
traefik_app_ip     = yandex_vpc_address.traefik_app.internal_ipv4_address[0].address
vminsert_ip        = yandex_vpc_address.vminsert.internal_ipv4_address[0].address
```

`traefik_ip` удалить. Все ссылки на `local.traefik_ip` закроет Task 4.

- [ ] **Step 4: Проверка**

Run: `terraform validate`
Expected: Success.

---

### Task 2: Кластер `elastic` — node group master и data

**Files:**
- Modify: `k8s.tf`

**Interfaces:**
- Produces: output `elastic_credentials_command`, шесть node group `elastic-master-a|b|d` (cores 2, memory 4) и `elastic-data-a|b|d` (cores 8, memory 16)
- Consumes: `local.network_id`, subnet ids

- [ ] **Step 1: Переименовать кластер и node group**

`yandex_kubernetes_cluster.elastic_chaos`: `name = "elastic"`.
Удалить ресурсы `elastic-a|b|d`. Добавить шесть: `elastic_master_a|b|d` и `elastic_data_a|b|d`.

Master зоны `a` (для `b`/`d` — суффикс и `local.subnet_b_*`/`local.subnet_d_*`):

```hcl
resource "yandex_kubernetes_node_group" "elastic_master_a" {
  name        = "elastic-master-a"
  description = "Elasticsearch master in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy { fixed_scale { size = 1 } }
  allocation_policy { location { zone = local.subnet_a_zone } }

  instance_template {
    platform_id = "standard-v3"
    network_interface {
      nat        = false
      subnet_ids = [local.subnet_a_id]
    }
    resources { cores = 2; memory = 4 }
    boot_disk { type = "network-hdd"; size = 64 }
    scheduling_policy { preemptible = true }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}
```

Data зоны `a` — тот же шаблон, `cores = 8`, `memory = 16`, `name = "elastic-data-a"`, `size = 2`.

- [ ] **Step 2: Outputs**

Заменить `k8s_cluster_credentials_command` на:

```hcl
output "elastic_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.elastic_chaos.id} --external --force --context-name elastic"
}
```

`zone_isolation_sg_id` — SG `zone_isolation`. `nlb_subnet_id` — подсеть `a`.

- [ ] **Step 3: Проверка**

Run: `terraform validate && terraform fmt -check k8s.tf`
Expected: Success, пустой `fmt -check`. Против имени `elastic-a` совпадений нет.

Переименование кластера — смена ресурса с новым id при изменении `name` в state. Перед apply спросить: state move или новый кластер. Apply не в этой задаче.

---

### Task 3: Кластер `app`

**Files:**
- Create: `k8s-app.tf`

**Interfaces:**
- Produces: `yandex_kubernetes_cluster.app`, output `app_credentials_command`
- Consumes: тот же SA, те же subnet ids

- [ ] **Step 1: Кластер**

Скопировать структуру master из `k8s.tf`: regional `ru-central1`, location a/b/d, `version = "1.33"`, release `STABLE`, `public_ip = true`, SA `elastic-chaos-monkey`. `name = "app"`. `cluster_ipv4_range`/`service_ipv4_range` другие, чтобы не конфликтовать с `elastic`. `depends_on = [time_sleep.wait_sa, time_sleep.wait_lb_release]`.

- [ ] **Step 2: Три node group**

`app-a`, `app-b`, `app-d`. `cores = 4`, `memory = 8`, boot `network-hdd` 64, `nat = false`, preemptible, version `1.33`, fixed scale 1. У каждой `lifecycle.ignore_changes` на `security_group_ids`.

- [ ] **Step 3: Output**

```hcl
output "app_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.app.id} --external --force --context-name app"
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
- Produces: `traefik-elastic-values.yaml`, `traefik-app-values.yaml`, `vmks-values.yaml`

- [ ] **Step 1: Два файла Traefik**

`monitoring.tf` рендерит два `local_file`: `traefik-elastic-values.yaml` (IP `10.0.1.33`) и `traefik-app-values.yaml` (IP `10.0.1.34`). Шаблон тот же: replicas 3, internal LB, `loadBalancerIP`, subnet annotation.

- [ ] **Step 2: vmks на IP app**

В `vmks-values.yaml.tftpl` ingress Grafana host `grafana.${ingress_ip}.sslip.io`, `ingress_ip` = public IP Traefik app. Control-plane disable не трогать.

- [ ] **Step 3: Chaos Mesh dashboard**

Шаблон `chaos-mesh-values.yaml.tftpl` рендерит два файла: `chaos-mesh-elastic-values.yaml` (host `10.0.1.33`) и `chaos-mesh-app-values.yaml` (host `10.0.1.34`). Controller `replicaCount: 3`.

- [ ] **Step 4: Outputs**

`grafana_url` = `http://grafana.<public IP Traefik app>.sslip.io`. `kibana_url` = `http://kibana.<public IP Traefik elastic>.sslip.io`. Удалить `es_nlb_ip`. `kibana_elastic_password_command`: secret `elastic-es-elastic-user`.

- [ ] **Step 5: Проверка**

Run: `terraform validate`
Expected: Success.

---

### Task 5: Elasticsearch ECK — шесть nodeSet и Ingress

**Files:**
- Modify: `manifests/eck/elasticsearch.yaml`, `manifests/eck/kibana.yaml`, `manifests/ingress/kibana.yaml`, `scripts/apply-eck.sh`
- Create: `manifests/ingress/elasticsearch.yaml`

**Interfaces:**
- Produces: Service `elastic-es-http` ClusterIP, Ingress `elastic.10.0.1.33.sslip.io` → `:9200`
- Consumes: Traefik кластера `elastic`

- [ ] **Step 1: CR Elasticsearch**

`metadata.name: elastic`. Убрать блок `http.service` с LoadBalancer (остаётся ClusterIP). Шесть nodeSet:

- `master-a|b|d` (count 1): `node.roles: ["master"]`, PVC **20 ГиБ** `yc-network-ssd`, CPU 1/1, RAM 2 ГиБ, heap `-Xms1g -Xmx1g`.
- `data-a|b|d` (count 2): `node.roles: ["data", "ingest"]`, `node.attr.zone`, awareness attributes `zone`, force на три зоны, PVC **50 ГиБ**, CPU 4/6, RAM 6 ГиБ, heap `-Xms3g -Xmx3g`.

Анонимный superuser оставить. `master` — **с PVC** по контракту.

- [ ] **Step 2: Kibana и Ingress**

В `kibana.yaml` `elasticsearchRef.name: elastic`.
В `ingress/kibana.yaml` host `kibana.<PUBLIC_IP>.sslip.io`, backend Service `elastic-kb-http:5601` (имя от CR `elastic`).
Новый `manifests/ingress/elasticsearch.yaml`: Ingress class `traefik`, host `elastic.<internal IP Traefik elastic>.sslip.io`, backend `elastic-es-http:9200`, namespace `elastic`.

- [ ] **Step 3: apply-eck.sh**

Убрать `ES_NLB_IP`. Ingress Kibana через public IP, Ingress ES через internal IP Traefik elastic.

- [ ] **Step 4: Exporter**

В `manifests/exporter/elasticsearch-exporter.yaml` URI `http://elastic-es-http.elastic.svc:9200`. Реплики 3 и spread не менять.

- [ ] **Step 5: Проверка ролей**

```bash
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("manifests/eck/elasticsearch.yaml"))
sets = doc["spec"]["nodeSets"]
assert [s["name"] for s in sets] == ["master-a","master-b","master-d","data-a","data-b","data-d"]
for s in sets:
    roles = s["config"]["node.roles"]
    assert "volumeClaimTemplates" in s, s["name"]
    if s["name"].startswith("master"):
        assert roles == ["master"] and s["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "20Gi", s["name"]
    else:
        assert roles == ["data", "ingest"] and s["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "50Gi", s["name"]
print("ok")
PY
```

Expected: `ok`.

---

### Task 6: Go loadgen

**Files:**
- Create: `loadgen/go.mod`, `loadgen/main.go`, `loadgen/main_test.go`, `loadgen/Dockerfile`

**Interfaces:**
- Produces: флаги `-es` (URL), метрики Prometheus `:8080`: `loadgen_bulk_ok_total`, `loadgen_bulk_err_total`, `loadgen_search_ok_total`, `loadgen_search_err_total`
- Consumes: ES HTTP без TLS и без пароля

Документ, пока не переспросили поля: JSON `{"id":"<uuid>","ts":"<RFC3339>","zone":"<hostname zone or empty>","body":"<padding>"}`, сериализованный размер 2048 байт. Индекс `load`: 1 primary, 2 replica. Не geo.

- [ ] **Step 1: Падающий тест размера**

```go
func TestDocSize(t *testing.T) {
    b := doc("id-1", time.Unix(0, 0).UTC(), "")
    if len(b) != 2048 { t.Fatalf("size %d", len(b)) }
}
```

Run: `cd loadgen && go test -count=1 .`
Expected: FAIL, `doc` не определён.

- [ ] **Step 2: Реализация doc**

`body` добивает JSON до 2048 байт. Поля длиннее 2048 — panic в тесте.

- [ ] **Step 3: Тест проходит**

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.

- [ ] **Step 4: Две горутины**

`main`: bulk и search с первой секунды. Index `load`, `ensureIndex` 1 primary / 2 replica. Ошибки HTTP и item-level bulk увеличивают `*_err_total`.

- [ ] **Step 5: Тест счётчика**

`httptest.Server`: успешный bulk item → `bulk_ok_total == 1`, ответ 500 → `bulk_err_total == 1`.

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.

---

### Task 7: Chart loadgen, vminsert NLB, vmagent

**Files:**
- Уже есть: `loadgen/chart/` (`replicaCount: 60`), `manifests/vminsert/nlb.yaml`

**Interfaces:**
- Consumes: `loadgen` image, `local.vminsert_ip`, ES Ingress URL
- Produces: Deployment `loadgen`, spread по зонам, env `ES_URL`

- [ ] **Step 1: Chart**

Deployment `loadgen`, namespace `load`, `replicaCount: 60`. `topologySpreadConstraints` по зоне. Env `ES_URL=http://elastic.10.0.1.33.sslip.io`. Service `:8080` для scrape. `VMServiceScrape` namespace `load`.

- [ ] **Step 2: vminsert NLB**

Service в namespace `vmks`, selector `app.kubernetes.io/name: vminsert`, LoadBalancer internal, subnet `a`, `loadBalancerIP: 10.0.1.35`, порт 8480.

- [ ] **Step 3: vmagent в кластере elastic**

Remote write уже в `vmks-elastic-values.yaml`: `http://10.0.1.35:8480/insert/0/prometheus`. Второй vmagent не ставить.

---

### Task 8: Скрипты изоляции любой зоны

**Files:**
- Create: `scripts/isolate-zone.sh`, `scripts/restore-zone.sh`
- Modify: `scripts/verify-ng-isolation-sg.sh`
- Delete: `scripts/isolate-zone-b.sh`, `scripts/restore-zone-b.sh`

**Interfaces:**
- Consumes: контексты `elastic` и `app`, output `zone_isolation_sg_id`
- Produces: `./scripts/isolate-zone.sh ru-central1-a|b|d`, state `.state/zone-isolate.env`

- [ ] **Step 1: isolate-zone.sh**

Аргумент — зона `ru-central1-a|b|d`. Node group: `elastic-master-<suffix>`, `elastic-data-<suffix>`, `app-<suffix>`.
Сохранить SG трёх групп. Пустой SG на все три. `disable-zones` на NLB Traefik elastic и NLB `vminsert`. Между `disable-zones` пауза 120 секунд. State-ключи: `ELASTIC_MASTER_NG`, `ELASTIC_DATA_NG`, `APP_NG`, `ELASTIC_MASTER_SG`, `ELASTIC_DATA_SG`, `APP_SG`, `NLB_TRAEFIK_ID`, `NLB_VMINSERT_ID`.

- [ ] **Step 2: restore-zone.sh**

Читает state, возвращает SG трём группам, `enable-zones` на оба NLB, удаляет state. Старый state с `ELASTIC_NG` (без новых ключей) → «state неполный», exit 1.

- [ ] **Step 3: verify-ng-isolation-sg.sh**

Аргументы: `<isolation-sg-id> <zone> <node-group>`. `VERDICT: HOT-REPLACE` (SG на живой VM) или `VERDICT: RECREATE`. Не ссылаться только на `isolate-zone-b.sh`.

- [ ] **Step 4: Проверка синтаксиса**

Run: `bash -n scripts/isolate-zone.sh && bash -n scripts/restore-zone.sh && bash -n scripts/verify-ng-isolation-sg.sh`
Expected: пустой вывод, код 0.

---

### Task 9: Chaos CR и прогон

**Files:**
- Modify: `manifests/chaos/pod-kill.yaml`, `network-loss.yaml`, `network-delay.yaml`
- Create: `scripts/chaos-run.sh`, `manifests/chaos/pod-kill-loadgen.yaml`, `network-loss-loadgen.yaml`, `network-delay-loadgen.yaml`

**Interfaces:**
- Consumes: контексты, `isolate-zone.sh` / `restore-zone.sh`
- Produces: `./scripts/chaos-run.sh` — зоны a, b, d по очереди

- [ ] **Step 1: CR Elasticsearch**

Селектор `elasticsearch.k8s.elastic.co/cluster-name: elastic`. Loss `30`, delay `500ms`, `direction: both`. Зона — плейсхолдер `ZONE`. `pod-kill.yaml`: `mode: all`, selector по зоне, окно держит скрипт.

- [ ] **Step 2: CR loadgen**

Те же три вида в namespace `load`, selector `app: loadgen`, `direction: both`.

- [ ] **Step 3: chaos-run.sh**

Порядок зон: `a`, `b`, `d`. Шаг хаоса — 2 минуты. На зону, оба контекста: 2 минуты pod-kill (цикл apply/sleep 30), 2 минуты покой, 2 минуты loss, покой, 2 минуты delay, покой, 2 минуты изоляция, restore, покой. Печатать счётчики bulk/search и `_count` после каждого шага. Стоп по Ctrl-C: удалить Chaos CR, restore если есть state.

- [ ] **Step 4: Синтаксис**

Run: `bash -n scripts/chaos-run.sh`
Expected: код 0.

---

### Task 10: Документы, агенты, удаление Rally

**Files:**
- Delete: `rally-vm.tf`, `cloud-init/rally.yaml`, `scripts/chaos-loop.sh`
- Modify: `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`, `.opencode/agents/chaos-check.md`, `.opencode/agents/script-runner.md`

- [ ] **Step 1: Удалить Rally**

Удалить файлы. В `scripts/check-count.sh` и `sample-mget.sh` индекс по умолчанию `load`.

- [ ] **Step 2: AGENTS.md**

Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`. `verify-ng-isolation-sg.sh` для каждой изолируемой node group в её контексте; при `VERDICT: RECREATE` isolate/restore не использовать.

- [ ] **Step 3: INFRASTRUCTURE.md**

Два кластера, шесть node group elastic (master/data) + три app, IP `10.0.1.33/34/35`. Изоляция: SG на `elastic-master-*`, `elastic-data-*`, `app-*` зоны, `disable-zones` только NLB Traefik elastic и NLB `vminsert`.

- [ ] **Step 4: README**

Статья по спеке: путь app → Traefik elastic → ES, четыре шага по трём зонам, критерии без порога. Таблица результатов — плейсхолдеры. Команды helm для двух контекстов.

- [ ] **Step 5: Агенты**

`script-runner`: esrally убрать. `chaos-check`: не только зона `b`, NLB — Traefik elastic и `vminsert`.

- [ ] **Step 6: Поиск Rally**

Run: `rg -n 'rally|esrally|10\.0\.4\.0/24|chaos-es-http|isolate-zone-b|elastic-a\b' README.md INFRASTRUCTURE.md AGENTS.md .opencode scripts manifests *.tf`
Expected: совпадений в актуальных документах и коде нет.

---

### Task 11: Тесты Review Focus

**Files:**
- Create: `loadgen/loss_test.go`

- [ ] **Step 1: Тест «bulk до сбоя виден в mget»**

`httptest`: функция bulk пишет документ, сервер сохраняет id, `mget` по id возвращает found.

- [ ] **Step 2: Проверка селектора зоны**

Run: `ZONE=ru-central1-a envsubst < manifests/chaos/pod-kill.yaml | grep -c ru-central1-a`
Expected: 1.

- [ ] **Step 3: go test**

Run: `cd loadgen && go test -count=1 .`
Expected: PASS.

---

## Заметки исполнителю

Стенд dedicated уже стоит. `terraform apply` и повторный `kubectl apply` манифеста ECK сносят текущие ноды и PVC. Не запускать.

Remote write vmagent кластера `elastic` — в `vmks-elastic-values.yaml`. Второй vmagent не ставить: будет двойная запись в `10.0.1.35`.

Перед прогоном изоляции — `./scripts/verify-ng-isolation-sg.sh` на `elastic-master-*`, `elastic-data-*` и `app-*`. При `VERDICT: RECREATE` isolate/restore не использовать.