# Разделение Elasticsearch master и data — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить три mixed-ноды Elasticsearch на 3 dedicated master и 3 data в зонах `a`/`b`/`d`, чтобы изоляция одной зоны гасила обе роли и оставляла кворум master.

**Architecture:** В кластере `elastic` шесть node group: `elastic-master-*` (2 vCPU / 4 ГБ) и `elastic-data-*` (8 vCPU / 16 ГБ). Один ресурс ECK `elastic` с шестью nodeSet. Isolate/restore вешает пустой SG на master, data и app этой зоны. Кластер `app` и Chaos Mesh CR не меняются.

**Tech Stack:** Terraform (`yandex_kubernetes_node_group`), ECK Elasticsearch 9.5.4, bash + `yc` CLI.

**Spec:** [docs/superpowers/specs/2026-09-25-elastic-master-data-split-design.md](../specs/2026-09-25-elastic-master-data-split-design.md)

## Global Constraints

- Node group `elastic`: preemptible, HDD, без публичного IP. Master 2 vCPU / 4 ГБ. Data 8 vCPU / 16 ГБ.
- Имена: `elastic-master-a|b|d`, `elastic-data-a|b|d`. Группы `elastic-a|b|d` удалить.
- `lifecycle.ignore_changes` на `security_group_ids` у каждой из шести групп.
- Кластер `app` не менять. Версию Kubernetes 1.33 не менять. `master.public_ip` k8s не трогать.
- ECK: один ресурс `elastic`, версия 9.5.4. Master: `node.roles: ["master"]`, без PVC, CPU 1/1, RAM 2 ГиБ, heap 1 ГиБ. Data: `node.roles: ["data", "ingest"]`, PVC 50 ГиБ `yc-network-ssd`, CPU 4/6, RAM 6 ГиБ, heap 3 ГиБ.
- Awareness `zone` и force на три зоны только у data. Индекс 1 primary + 2 replica не менять в этом плане (его задаёт loadgen, не этот манифест).
- Зону ломать только `./scripts/isolate-zone.sh`, чинить только `./scripts/restore-zone.sh`. `terraform apply` для переключения изоляции не применять.
- `disable-zones` не чаще раза в 2 минуты на один NLB. Паузу в скрипте не убирать.
- Коммиты — существительное, не инфинитив. Не коммитить, пока пользователь явно не попросил в сессии исполнения. Шаги Commit ниже — для исполнителя после явного запроса.

## Review Focus

- Старый state `.state/zone-isolate.env` с `ELASTIC_NG=elastic-a` после смены имён: restore должен отказаться, а не повесить SG не на ту группу.
- Master-nodeSet с `volumeClaimTemplates`: появится PVC и данные на master. Проверка — отсутствие `volumeClaimTemplates` у `master-*`.
- Data без `node.roles: ["data", "ingest"]`: шарды некуда положить, кластер не green. Проверка — роли в манифесте.
- Isolate обновляет только одну из `elastic-master-*` / `elastic-data-*`: зона не отвалится целиком. Проверка — оба имени в вызове `yc`.
- `elastic-a` остаётся в `k8s.tf`: apply поднимет седьмую ноду. Проверка — `terraform validate` и отсутствие имени `elastic-a`.

---

### Task 1: Node group master и data

**Files:**
- Modify: `k8s.tf` (ресурсы `k8s_node_group_a|b|d`, строки 63–193)
- Test: `terraform validate` (локально, без apply)

**Interfaces:**
- Consumes: `yandex_kubernetes_cluster.elastic_chaos.id`, `local.subnet_a_zone`, `local.subnet_a_id` и пары `b`/`d`
- Produces: node group `elastic-master-a|b|d` (cores 2, memory 4), `elastic-data-a|b|d` (cores 8, memory 16). Ресурсов `elastic-a|b|d` нет.

- [ ] **Step 1: Заменить три node group на шесть**

Удалить ресурсы `k8s_node_group_a`, `k8s_node_group_b`, `k8s_node_group_d`.

Добавить шесть ресурсов. Шаблон master для зоны `a` (для `b` и `d` — суффикс, `local.subnet_b_*` / `local.subnet_d_*`):

```hcl
resource "yandex_kubernetes_node_group" "elastic_master_a" {
  name        = "elastic-master-a"
  description = "Elasticsearch master in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_a_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [local.subnet_a_id]
    }

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}
```

Шаблон data для зоны `a` (cores 8, memory 16; `b`/`d` аналогично):

```hcl
resource "yandex_kubernetes_node_group" "elastic_data_a" {
  name        = "elastic-data-a"
  description = "Elasticsearch data in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_a_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [local.subnet_a_id]
    }

    resources {
      cores  = 8
      memory = 16
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}
```

Имена ресурсов: `elastic_master_a|b|d`, `elastic_data_a|b|d`. Output'ы в конце `k8s.tf` не менять.

- [ ] **Step 2: Проверить план Terraform**

Run: `terraform validate && terraform fmt -check k8s.tf`

Expected: `Success! The configuration is valid.` и пустой вывод `fmt -check`.

Не запускать `terraform apply`. Смена node group на живом кластере удалит `elastic-a|b|d` и создаст шесть новых — это отдельное решение пользователя, не шаг плана.

- [ ] **Step 3: Commit**

```bash
git add k8s.tf
git commit -m "разделение node group elastic на master и data"
```

Только если пользователь явно попросил коммит.

### Task 2: Манифест ECK

**Files:**
- Modify: `manifests/eck/elasticsearch.yaml`

**Interfaces:**
- Consumes: node group из Task 1 только через `nodeSelector` зоны, не через имя группы
- Produces: nodeSet `master-a|b|d`, `data-a|b|d` в ресурсе `elastic`

- [ ] **Step 1: Переписать nodeSets**

Оставить `apiVersion`, `kind`, `metadata`, `spec.version`, `spec.http` как есть.

Заменить три nodeSet `zone-a|b|d` на шесть. Master зоны `a` (для `b`/`d` сменить зону в имени, `nodeSelector` и не добавлять `node.attr`):

```yaml
    - name: master-a
      count: 1
      config:
        node.roles: ["master"]
        xpack.security.authc.anonymous.username: anonymous
        xpack.security.authc.anonymous.roles: superuser
        xpack.security.authc.anonymous.authz_exception: false
      podTemplate:
        spec:
          nodeSelector:
            topology.kubernetes.io/zone: ru-central1-a
          initContainers:
            - name: sysctl
              securityContext:
                privileged: true
                runAsUser: 0
              command: ['sh', '-c', 'sysctl -w vm.max_map_count=1048576']
          containers:
            - name: elasticsearch
              env:
                - name: ES_JAVA_OPTS
                  value: -Xms1g -Xmx1g
              resources:
                requests:
                  cpu: "1"
                  memory: 2Gi
                limits:
                  cpu: "1"
                  memory: 2Gi
```

У master нет `volumeClaimTemplates`.

Data зоны `a` (для `b`/`d` сменить имя, `node.attr.zone`, `nodeSelector`):

```yaml
    - name: data-a
      count: 1
      config:
        node.roles: ["data", "ingest"]
        node.attr.zone: ru-central1-a
        cluster.routing.allocation.awareness.attributes: zone
        cluster.routing.allocation.awareness.force.zone.values: ru-central1-a,ru-central1-b,ru-central1-d
        xpack.security.authc.anonymous.username: anonymous
        xpack.security.authc.anonymous.roles: superuser
        xpack.security.authc.anonymous.authz_exception: false
      podTemplate:
        spec:
          nodeSelector:
            topology.kubernetes.io/zone: ru-central1-a
          initContainers:
            - name: sysctl
              securityContext:
                privileged: true
                runAsUser: 0
              command: ['sh', '-c', 'sysctl -w vm.max_map_count=1048576']
          containers:
            - name: elasticsearch
              env:
                - name: ES_JAVA_OPTS
                  value: -Xms3g -Xmx3g
              resources:
                requests:
                  cpu: "4"
                  memory: 6Gi
                limits:
                  cpu: "6"
                  memory: 6Gi
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes:
              - ReadWriteOnce
            storageClassName: yc-network-ssd
            resources:
              requests:
                storage: 50Gi
```

Не применять манифест в кластер в этом плане. Смена nodeSet на живом ES удалит mixed-поды и их PVC — отдельное решение пользователя.

- [ ] **Step 2: Проверить роли в файле**

Run:

```bash
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("manifests/eck/elasticsearch.yaml"))
sets = doc["spec"]["nodeSets"]
assert [s["name"] for s in sets] == [
    "master-a", "master-b", "master-d",
    "data-a", "data-b", "data-d",
]
for s in sets:
    roles = s["config"]["node.roles"]
    if s["name"].startswith("master"):
        assert roles == ["master"], s["name"]
        assert "volumeClaimTemplates" not in s, s["name"]
        assert s["podTemplate"]["spec"]["containers"][0]["env"][0]["value"] == "-Xms1g -Xmx1g"
    else:
        assert roles == ["data", "ingest"], s["name"]
        assert s["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "50Gi"
        assert "awareness.attributes" in s["config"]["cluster.routing.allocation.awareness.attributes"] or s["config"]["cluster.routing.allocation.awareness.attributes"] == "zone"
print("ok")
PY
```

Если `python3` без `yaml`, поставить `pip install pyyaml` в окружение пользователя не надо: тогда проверить `grep` — шесть имён nodeSet, три строки `node.roles: ["master"]`, три `["data", "ingest"]`, три `storage: 50Gi`, ноль `volumeClaimTemplates` в блоках master (у master блока нет).

Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add manifests/eck/elasticsearch.yaml
git commit -m "разделение nodeSet Elasticsearch на master и data"
```

Только если пользователь явно попросил коммит.

### Task 3: Isolate и restore двух node group elastic

**Files:**
- Modify: `scripts/isolate-zone.sh`
- Modify: `scripts/restore-zone.sh`

**Interfaces:**
- Consumes: имена node group из Task 1
- Produces: state-ключи `ELASTIC_MASTER_NG`, `ELASTIC_DATA_NG`, `ELASTIC_MASTER_SG`, `ELASTIC_DATA_SG`. Ключей `ELASTIC_NG` / `ELASTIC_SG` больше нет.

- [ ] **Step 1: Обновить isolate-zone.sh**

Заменить блок имён и чтения SG:

```bash
MASTER_NG="elastic-master-${SUFFIX}"
DATA_NG="elastic-data-${SUFFIX}"
APP_NG="app-${SUFFIX}"
MASTER_JSON="$(ng_json "$MASTER_NG")"
DATA_JSON="$(ng_json "$DATA_NG")"
APP_JSON="$(ng_json "$APP_NG")"
MASTER_SG="$(sg_of "$MASTER_JSON")"
DATA_SG="$(sg_of "$DATA_JSON")"
APP_SG="$(sg_of "$APP_JSON")"
MASTER_SUBNETS="$(subnets_of "$MASTER_JSON")"
DATA_SUBNETS="$(subnets_of "$DATA_JSON")"
APP_SUBNETS="$(subnets_of "$APP_JSON")"
```

State-файл:

```bash
cat > "$STATE_FILE" <<EOF
ZONE=$ZONE
ELASTIC_MASTER_NG=$MASTER_NG
ELASTIC_DATA_NG=$DATA_NG
APP_NG=$APP_NG
ELASTIC_MASTER_SG=$MASTER_SG
ELASTIC_DATA_SG=$DATA_SG
APP_SG=$APP_SG
NLB_TRAEFIK_ID=$NLB_TRAEFIK_ID
NLB_VMINSERT_ID=$NLB_VMINSERT_ID
EOF
```

Вызовы update — три, не два. `sleep 120` между `disable-zones` оставить:

```bash
echo "isolate $ZONE sg=$SG_ID ng=$MASTER_NG,$DATA_NG,$APP_NG"
yc managed-kubernetes node-group update "$MASTER_NG" --network-interface "subnets=${MASTER_SUBNETS},security-group-ids=[${SG_ID}]"
yc managed-kubernetes node-group update "$DATA_NG" --network-interface "subnets=${DATA_SUBNETS},security-group-ids=[${SG_ID}]"
yc managed-kubernetes node-group update "$APP_NG" --network-interface "subnets=${APP_SUBNETS},security-group-ids=[${SG_ID}]"
yc load-balancer network-load-balancer disable-zones --id "$NLB_TRAEFIK_ID" --zones "$ZONE"
sleep 120
yc load-balancer network-load-balancer disable-zones --id "$NLB_VMINSERT_ID" --zones "$ZONE"
echo "zone $ZONE isolated"
```

- [ ] **Step 2: Обновить restore-zone.sh**

Инициализация и проверка state:

```bash
ZONE="" ELASTIC_MASTER_NG="" ELASTIC_DATA_NG="" APP_NG="" ELASTIC_MASTER_SG="" ELASTIC_DATA_SG="" APP_SG="" NLB_TRAEFIK_ID="" NLB_VMINSERT_ID=""
# shellcheck disable=SC1090
source "$STATE_FILE"
if [ -z "$ZONE" ] || [ -z "$ELASTIC_MASTER_NG" ] || [ -z "$ELASTIC_DATA_NG" ] || [ -z "$APP_NG" ] || [ -z "$NLB_TRAEFIK_ID" ] || [ -z "$NLB_VMINSERT_ID" ]; then
  echo "state неполный" >&2
  exit 1
fi
```

Функцию `restore_ng` не менять. Вызовы:

```bash
restore_ng "$ELASTIC_MASTER_NG" "$ELASTIC_MASTER_SG"
restore_ng "$ELASTIC_DATA_NG" "$ELASTIC_DATA_SG"
restore_ng "$APP_NG" "$APP_SG"
```

`enable-zones` и `rm` state оставить как есть.

Старый state с `ELASTIC_NG` без новых ключей даёт `state неполный` и exit 1. Это намеренно: не восстанавливать по устаревшему имени `elastic-a`.

- [ ] **Step 3: Проверить скрипты без yc**

Run:

```bash
bash -n scripts/isolate-zone.sh && bash -n scripts/restore-zone.sh
grep -n 'elastic-${SUFFIX}' scripts/isolate-zone.sh && exit 1 || true
grep -c 'elastic-master-${SUFFIX}' scripts/isolate-zone.sh
grep -c 'elastic-data-${SUFFIX}' scripts/isolate-zone.sh
```

Expected: синтаксис чистый, первая `grep` ничего не печатает (старого имени нет), оба счётчика `1`.

Не вызывать isolate/restore на живом кластере.

- [ ] **Step 4: Commit**

```bash
git add scripts/isolate-zone.sh scripts/restore-zone.sh
git commit -m "изоляция master и data node group зоны"
```

Только если пользователь явно попросил коммит.

### Task 4: Документы

**Files:**
- Modify: `README.md` (строки 15, 22, 105–108)
- Modify: `INFRASTRUCTURE.md` (строки 3, 27, 29)
- Modify: `docs/superpowers/specs/2026-09-24-elastic-chaos-two-clusters-design.md` (строки 51–69, 122)

**Interfaces:**
- Consumes: имена и размеры из Task 1 и Task 2
- Produces: нет кода

- [ ] **Step 1: README**

Строка стенда:

`| Elasticsearch 9.5.4 master ×3 + data ×3 | кластер elastic, зоны a/b/d; data PVC 50 ГиБ yc-network-ssd, heap 3 ГиБ; master без PVC, heap 1 ГиБ |`

Строка нод:

`Ноды без публичного IP, HDD, preemptible. elastic: master 2 vCPU / 4 ГБ, data 8 vCPU / 16 ГБ. app: 4 vCPU / 8 ГБ. SA elastic-chaos-monkey. Kubernetes 1.33.`

Пример verify: `elastic-master-a` и `elastic-data-a` вместо `elastic-a`. Следующая фраза перечисляет `elastic-master-b`, `elastic-master-d`, `elastic-data-b`, `elastic-data-d` и `app-a|b|d`.

- [ ] **Step 2: INFRASTRUCTURE.md**

Первый абзац: кластер `elastic` — шесть node group, master 2 vCPU / 4 ГБ и data 8 vCPU / 16 ГБ, по одной в `a`/`b`/`d`. `app` — три node group 4 vCPU / 8 ГБ. Остальное предложение (HDD, без публичного IP, NAT, NLB) оставить.

Строка про `ignore_changes`: «у всех девяти node group» (6 elastic + 3 app), не «у всех шести».

Строка Isolate: пустой SG на `elastic-master-*`, `elastic-data-*` и `app-*` этой зоны.

- [ ] **Step 3: Спека 2026-09-24**

В разделе Kubernetes заменить таблицу нод `es | 8 vCPU / 16 ГБ` на две строки: master 2 vCPU / 4 ГБ, data 8 vCPU / 16 ГБ. Предложение «оба кластера: три node group» заменить: `elastic` — шесть node group, `app` — три.

В разделе Elasticsearch заменить пункт про три mixed-ноды на отсылку: роли и размеры — в [2026-09-25-elastic-master-data-split-design.md](2026-09-25-elastic-master-data-split-design.md). Пункт PVC 100 ГиБ удалить (в новой спеке 50 ГиБ). Пункты CPU/RAM mixed удалить.

В шаге изоляции: пустой SG на node group `elastic-master-*`, `elastic-data-*` и `app-*` этой зоны, не «на node group этой зоны в обоих кластерах» без имён.

Строку «Сравнение mixed vs dedicated» во «Вне скоупа» оставить: сравнение как эксперимент по-прежнему вне скоупа, dedicated уже выбран.

- [ ] **Step 4: Проверить, что старые имена не остались в живых документах**

Run:

```bash
rg -n 'elastic-a|mixed ×3|ноды 8 vCPU / 16 ГБ' README.md INFRASTRUCTURE.md docs/superpowers/specs/2026-09-24-elastic-chaos-two-clusters-design.md
```

Expected: нет совпадений. Совпадения в `docs/superpowers/plans/2026-09-25-two-clusters.md` и в спеке 2026-09-18 не трогать: это история, не контракт.

- [ ] **Step 5: Commit**

```bash
git add README.md INFRASTRUCTURE.md docs/superpowers/specs/2026-09-24-elastic-chaos-two-clusters-design.md
git commit -m "обновление контракта dedicated master и data"
```

Только если пользователь явно попросил коммит.

## Заметки исполнителю

`terraform apply` и `kubectl apply` манифеста ECK в этот план не входят. Они уничтожат текущие mixed-ноды и PVC. Делать только по отдельной команде пользователя, после Task 1–4.

Перед первым прогоном изоляции на новом стенде — `./scripts/verify-ng-sg-swap.sh` на `elastic-master-*`, `elastic-data-*` и `app-*`. При `VERDICT: RECREATE` скрипты не использовать.
