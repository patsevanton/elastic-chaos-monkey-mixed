# Разделение Elasticsearch master и data

Дата: 2026-09-25
Репозиторий: `elastic-chaos-monkey-mixed`
Уточняет [2026-09-24-elastic-chaos-two-clusters-design.md](2026-09-24-elastic-chaos-two-clusters-design.md) в части ролей нод Elasticsearch и node group кластера `elastic`. Остальное из той спеки действует.

## Цель

Один кластер Elasticsearch переживает отказ одной зоны, когда master и data — разные роли. Изоляция зоны гасит оба pod'а этой зоны. Кворум master остаётся: живы 2 из 3.

Успех: search жив, index жив, нет потери документов, которые bulk принял до сбоя. Пока зона изолирована, кластер yellow. После restore — green, копия шарда садится сама.

## Вне скоупа

- Второй кластер Elasticsearch.
- Смена версии Elasticsearch, ECK, Kubernetes, ingress.
- Кластер `app`: размеры нод, число node group, приложение.
- Traefik, Kibana, exporter, Headscale, порядок зон, длительность шагов.
- Сравнение mixed vs dedicated как отдельный эксперимент. Эта спека заменяет mixed на dedicated.
- Power-off VM.

## Kubernetes, кластер elastic

Шесть node group, по одной preemptible-ноде, загрузочный диск HDD, без публичного IP. Зоны `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.

| Группа | Роль | VM |
|---|---|---|
| `elastic-master-a`, `elastic-master-b`, `elastic-master-d` | master | 2 vCPU / 4 ГБ |
| `elastic-data-a`, `elastic-data-b`, `elastic-data-d` | data | 8 vCPU / 16 ГБ |

`lifecycle.ignore_changes` на `security_group_ids` — у каждой из шести групп, как у текущих `elastic-a/b/d`.

Группы `elastic-a`, `elastic-b`, `elastic-d` удаляются. Кластер `app` не меняется.

## Elasticsearch

Один ресурс ECK, имя `elastic`, версия 9.5.4. Шесть nodeSet, `count: 1`. `nodeSelector` `topology.kubernetes.io/zone` на зону nodeSet.

Master (`master-a`, `master-b`, `master-d`):

- `node.roles: ["master"]`
- PVC нет
- CPU request 1, limit 1
- RAM 2 ГиБ, heap 1 ГиБ (`-Xms1g -Xmx1g`)

Data (`data-a`, `data-b`, `data-d`):

- `node.roles: ["data", "ingest"]`
- PVC 50 ГиБ `yc-network-ssd`
- CPU request 4, limit 6
- RAM 6 ГиБ, heap 3 ГиБ
- `node.attr.zone` — зона nodeSet
- `cluster.routing.allocation.awareness.attributes: zone`
- `cluster.routing.allocation.awareness.force.zone.values`: `ru-central1-a,ru-central1-b,ru-central1-d`

Индекс нагрузки: 1 primary + 2 replica. HTTP без TLS и без пароля. Анонимный superuser — как в текущем манифесте.

Voting-only и ingest на master не добавляем. Coordinating-only нод нет.

Пока зона изолирована: кластер yellow, кворум master жив, копия шарда этой зоны не аллоцируется на живые зоны. После restore копия садится сама. Ручной relocate не делаем.

Два master сразу — вне эксперимента. Изолируется одна зона, не две.

## Хаос

Селектор Chaos Mesh по `topology.kubernetes.io/zone` не меняется. Pod-kill, network loss и network delay зоны бьют master и data этой зоны.

`isolate-zone.sh` и `restore-zone.sh` вешают и снимают пустой SG с трёх node group зоны: `elastic-master-*`, `elastic-data-*`, `app-*`. `disable-zones` на NLB Traefik es и NLB `vminsert` без изменений. Пауза 2 минуты между `disable-zones` на одном NLB сохраняется.

Перед первым прогоном — `./scripts/verify-ng-sg-swap.sh` на каждую из шести node group `elastic` и на node group `app`, которые изолируются. При `VERDICT: RECREATE` isolate/restore не использовать.

## Документы

Обновить под dedicated: README, INFRASTRUCTURE.md, спеку 2026-09-24 (абзацы про три mixed-ноды и одну node group 8 vCPU / 16 ГБ на зону в кластере `elastic`). PVC в тексте — 50 ГиБ, не 100.

## Проверка

После apply: шесть нод `elastic` Ready, по зоне одна master и одна data; три ноды `app` без изменений. ES green. Master-pod'ы без PVC. Data-pod'ы с PVC 50 ГиБ. `_cat/nodes` показывает роли `m` и `di` в каждой зоне. Шарды индекса только на data, awareness по зоне.
