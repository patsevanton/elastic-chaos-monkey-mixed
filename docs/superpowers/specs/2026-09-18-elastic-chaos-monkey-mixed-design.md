# Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally

Дата: 2026-09-18 (доступ через Headscale — 2026-09-19)  
Репозиторий: `elastic-chaos-monkey-mixed`  
Формат: README = статья (как `k8s-descheduler-node-downscale`). Подход реализации: A — пошаговый стенд, хаос вручную.

## Цель

Стенд и статья доказывают, что Elasticsearch на трёх mixed-нодах в трёх зонах при прод-подобной нагрузке переживает:

1. убийство одного ES-пода;
2. деградацию сети (loss, затем delay) на ES-поде в одной зоне;
3. отвал зоны Yandex Cloud (`ru-central1-b`).

Критерии (все три): search жив, index жив, нет потери документов, успешно принятых bulk до сбоя. Порога «жив / не жив» по error-rate нет: в статье печатаем процент ошибок Rally.

Доступ к стенду с ноутбука: k8s API, Grafana/Kibana и Rally — только через Headscale. Публичный IP только у Headscale VM.

## Вне скоупа

Хаос и статья:

- IOChaos и отдельный «stop одной ноды без зоны» (в зоне одна нода: stop worker’а `b` = отвал AZ).
- Сравнение mixed vs dedicated, ECK vs Helm, второй ES-кластер.
- Публичный Elasticsearch, TLS/пароль на HTTP ES.
- Chaos Mesh Workflow как оркестратор трёх опытов.
- Автотесты хаоса в CI.
- Цифры результатов до прогона (в README плейсхолдеры).

Доступ:

- Headscale в Kubernetes.
- Caddy или Traefik на Headscale VM.
- Tailscale-клиент на нодах k8s и на Rally.
- Policy / ACL Headscale.
- Публичные Traefik, k8s master, Rally.
- Смена версии Kubernetes (остаётся 1.33).

## Архитектура

### Kubernetes

- Yandex Managed K8s **1.33**, Terraform.
- Service account: `elastic-chaos-monkey` (имя не копировать из других репозиториев).
- Три node group, по одной preemptible-ноде **8 vCPU / 16 ГБ**, загрузочный диск **HDD**, **без публичного IP**, NAT Gateway + Route Table.
- Зоны worker’ов: `ru-central1-a`, `ru-central1-b`, `ru-central1-d`.
- `master.public_ip = false`. Credentials: `yc managed-kubernetes cluster get-credentials --id ... --internal --force`.
- Terraform в k8s API не ходит: provider `helm` и `helm_release.traefik` нет.

Исключение из инфрах-правила HDD: **PVC Elasticsearch — `yc-network-ssd`**, **диск Rally VM — `network-ssd` 150 ГиБ**. Ноды k8s и Headscale VM — HDD.

### Доступ: Headscale

Единственный публичный адрес стенда — `yandex_vpc_address.ingress`, NAT на Headscale VM. Отдельный reserved IP для Headscale не создаём.

- Отдельная VM в **`ru-central1-a`**, не в k8s: **2 vCPU / 4 ГБ / HDD 20 ГиБ**, preemptible, образ Ubuntu как у Rally (`fd806c8slu9j1pa87msc`).
- NAT на этой VM нужен (клиенты и Let's Encrypt).
- На VM: сервер Headscale **0.29.3** (DEB) + Tailscale-клиент **1.102.4** как subnet router на `10.0.1.0/24`–`10.0.4.0/24`.
- HTTPS без reverse proxy: встроенный ACME HTTP-01. `server_url` и `tls_letsencrypt_hostname`: `headscale.<PIP>.sslip.io`. `listen_addr: :443`. SQLite в `/var/lib/headscale`.
- Embedded DERP, `derp.server.ipv4` = PIP, `derp.urls: []` (без карты Tailscale Inc.).
- Пользователь Headscale: `elastic-chaos`. Два reusable preauth, TTL 24 ч: router (эта VM) и ноутбук. Маршруты: `headscale nodes approve-routes`. IP forwarding включён.
- Ключ ноутбука — файл на VM, Terraform забирает по SSH → sensitive output.
- SSH публичный, ключ `~/.ssh/id_ed25519.pub` как у Rally.
- Порты с интернета: `80/tcp`, `443/tcp`, `3478/udp`, `22/tcp`. Security group не добавляем.
- LAN ноутбука `192.168.3.0/24` с VPC `10.0.x` не пересекается; CIDR VPC не сдвигаем.

Headscale — координатор и DERP. В `10.0.x` пакеты идут, потому что на VM включён клиент с advertise-routes.

### Elasticsearch (ECK)

- Elasticsearch **9.5.4**, ECK **3.5.0** (номера в README и манифестах).
- Три mixed-ноды (master + data + ingest), по одной в зоне (`a` / `b` / `d`).
- PVC **100 ГиБ** `yc-network-ssd` на ноду.
- CPU: requests **4**, limits **6**. RAM requests **6 ГиБ**, heap **3 ГиБ**.
- Индекс нагрузки: **1 primary + 2 replica**.
- `cluster.routing.allocation.awareness.attributes: zone`.
- `cluster.routing.allocation.awareness.force.zone.values: a,b,d`.
- HTTP: **без TLS и без пароля**. Transport между нодами — как в ECK по умолчанию.
- Доступ Rally: Service **internal LoadBalancer** (NLB в VPC), порт **9200**. ES в интернет не публикуем.

Пока зона `b` изолирована: кластер **yellow**, третья replica **не** аллоцируется на `a`/`d`. После `restore-zone-b.sh` replica садится на `b` сама. Ручной relocate шардов не делаем.

### Rally

- Отдельная VM в **`ru-central1-e`**: **8 vCPU / 16 ГБ**, SSD **150 ГиБ** (`network-ssd`), **без публичного IP** (`nat = false`).
- Исходящий трафик (apt, pip, esrally) — NAT Gateway и route table подсети `e`.
- SSH — внутренний IP после `tailscale up --accept-routes`.
- Cloud-init: esrally, каталог id-лога успешных bulk.
- Трек: **geoshape**, challenge **append-no-conflicts-big**. Сначала полный ingest, затем **4–6 часов** непрерывный mixed bulk+search.
- Зону `e` в экспериментах не стопаем.

### Наблюдение

- `victoria-metrics-k8s-stack` **0.92.1** в namespace **`vmks`**, helm CLI.
- VMCluster **replicationFactor: 3**, по одному `vmstorage` в `a`/`b`/`d`: **1 vCPU / 2 ГиБ RAM / HDD 30 ГиБ**.
- В values отключить scrape-job и recording-правила control-plane Yandex Managed K8s (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, группы `etcd`, `kubernetes-system-scheduler`, `kubernetes-system-controller-manager`, `kube-scheduler.rules`).
- Grafana: **1 реплика**, Ingress Traefik, `grafana.<INTERNAL_NLB_IP>.sslip.io`.
- Traefik: helm CLI, chart **41.6.0**, **3 реплики** в `a`/`b`/`d`. Values Terraform пишет на apply (`local_file.write_traefik_values`) из `traefik-values.yaml.tftpl`: Service LoadBalancer **internal**, `yandex.cloud/subnet-id` = subnet `a`, `loadBalancerIP` = reserved internal IP `yandex_vpc_address.traefik`.
- `time_sleep.wait_lb_release` остаётся: на destroy кластера CCM должен успеть снять internal NLB Traefik (60 с), как раньше для публичного Ingress.
- `vmks-values.yaml` Terraform пишет на apply (`local_file.write_vmks_values`) из `vmks-values.yaml.tftpl`, IP = reserved internal адрес Traefik.
- `prometheus-community/elasticsearch_exporter`: **3 реплики** в `a`/`b`/`d`.
- ECK operator и Chaos Mesh controller: **по 3 реплики**.
- Kibana (ECK): **3 реплики** в `a`/`b`/`d`, Ingress Traefik, `kibana.<INTERNAL_NLB_IP>.sslip.io`. **Basic auth на Ingress нет** — Traefik только из VPC/tailnet. Kibana ходит в ES без пароля. Переменная `kibana_ingress_password` и `htpasswd` не нужны. Stack Monitoring не заменяет Grafana.

### Хаос

Инструменты: Chaos Mesh (под, сеть) + сетевая изоляция зоны (пустой SG `zone-isolation` на node group + `disable-zones` на NLB). Не Litmus.

Последовательность на фоне mixed (каждый слот **~30–40 мин**):

1. **Pod kill** — один раз один ES-под, ждать восстановления ECK (не цикл Chaos Monkey).
2. **Сеть** — только ES-под в **`ru-central1-b`**: NetworkChaos **loss 30%**, откат, пауза, затем **delay 500 мс**, откат. Смысл — деградация в **оба** направления (`both`); в манифестах `manifests/chaos/network-*.yaml` поле `direction` пока не задано.
3. **Зона `b`** — `scripts/isolate-zone-b.sh` (пустой SG `zone-isolation` на node group `elastic-chaos-b` + `disable-zones ru-central1-b` на NLB `chaos-es-http` и `traefik`), выдержать, затем `scripts/restore-zone-b.sh`. VM остаётся `RUNNING`, отрезана сеть. Grafana/Traefik/exporter/ECK/Kibana живы в `a` и `d`. Headscale VM в `a` не трогаем.

Кворум: одновременно не больше одной mixed-ноды. Два master сразу — вне статьи.

## Потоки данных

```
Ноутбук --HTTPS :443 / STUN :3478 / WireGuard--> Headscale VM (публичный IP)
Ноутбук --WireGuard--> subnet router на Headscale VM --VPC--> 10.0.1.0/24 … 10.0.4.0/24
  → internal API master (kubectl)
  → internal NLB Traefik (Grafana, Kibana)
  → Rally 10.0.4.x:22
Rally --NAT Gateway--> интернет (пакеты, трек geoshape)
Rally --VPC--> internal NLB Elasticsearch :9200
```

- Rally VM → internal NLB `:9200` → три ES-пода. Kibana в путь нагрузки не входит.
- elasticsearch_exporter → ES HTTP без auth → vmagent → VMCluster. Grafana читает VM.
- Проценты ошибок Rally — с VM в таблицы README вручную.
- Браузер → tailnet → Traefik (`*.<internal-ip>.sslip.io`) → Kibana → ES без пароля.
- Chaos Mesh целится только в ES в зоне `b`. AZ-outage — изоляция SG + `disable-zones` на NLB (`isolate-zone-b.sh` / `restore-zone-b.sh`).

## Порядок после apply

1. `terraform apply` — сеть, k8s (приватный API), Rally без NAT, Headscale VM.
2. `terraform output` — публичный IP Headscale, FQDN, preauth ноутбука.
3. На ноутбуке: `tailscale up --login-server=https://headscale.<PIP>.sslip.io --auth-key=... --accept-routes`.
4. `yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force`.
5. Helm Traefik 41.6.0 → IP internal NLB.
6. Values для vmks (и Traefik/Chaos Mesh) пишет Terraform на apply из `*.yaml.tftpl`; подстановка IP в Ingress Kibana — `scripts/apply-eck.sh`.
7. Helm vmks **0.92.1**.
8. Дальше README: ECK, Chaos Mesh, Rally; SSH на Rally — внутренний IP.

## Проверка потери данных (после каждого слота)

1. Счётчик успешных bulk vs `GET _count`.
2. Id-лог на Rally VM + sample/`mget`.
3. Error-rate Rally (search и bulk отдельно), печатаем % без порога.

## Ошибки, откат, безопасность

- Откат NetworkChaos: удалить CR, дождаться чистой сети.
- PodChaos one-shot: откат = ECK поднимает под.
- Зона `b`: только `scripts/restore-zone-b.sh` (возврат SG + `enable-zones` на NLB), не `terraform apply`, не удаление node group, не power-off VM. VPN не падает (Headscale в `a`).
- Стоп-кран mixed: остановить Rally, `scripts/restore-zone-b.sh`, снять Chaos CR. Автоabort по SLO нет.
- Preemptible: посторонний stop Yandex не считать экспериментом; прогон короче ~24 ч. Убита не `b` во время слота — слот перезапустить.
- PVC ES зональные SSD: при изоляции `b` том остаётся в `b`, под не едет в `a`/`d`.
- Публично только Headscale VM (80, 443, 3478/udp, SSH). Grafana, Kibana, k8s API, Rally SSH — через tailnet. ES — VPC + internal NLB.
- ACME: `headscale.<PIP>.sslip.io` должен резолвиться в PIP до первого выпуска сертификата.
- Recreate Headscale VM: тот же зарезервированный PIP; если диск новый — новые preauth, ноутбук перелогинить.
- Cloud-init Headscale сломался: SSH ключом или serial console Yandex.

## Состав репозитория

Terraform в корне: `versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `net.tf`, `k8s.tf`, `ip-dns.tf`, `monitoring.tf`, `sg.tf`, `vmks-values.yaml.tftpl`, `traefik-values.yaml.tftpl`, `chaos-mesh-values.yaml.tftpl`, `rally-vm.tf`, `headscale-vm.tf`.

Cloud-init: `cloud-init/rally.yaml`, `cloud-init/headscale.yaml.tftpl`.

Манифесты:

- `manifests/eck/` — Elasticsearch CR, Kibana CR (operator ставится helm, манифеста нет).
- `manifests/chaos/` — PodChaos, NetworkChaos loss, NetworkChaos delay.
- `manifests/exporter/` — elasticsearch_exporter + VMServiceScrape (exporter, Chaos Mesh, Traefik).
- `manifests/chaos-mesh/` — RBAC и SA-токен для Chaos Dashboard.
- `manifests/ingress/` — Ingress Kibana без middleware basic auth.

`scripts/` — изоляция/восстановление зоны `b` (`isolate-zone-b.sh` / `restore-zone-b.sh`), `verify-ng-sg-swap.sh`, `chaos-loop.sh`, `check-chaos.sh`, `check-zone-b-down.sh`, `check-count.sh`, `sample-mget.sh`, `apply-eck.sh`, `download-geoshape.sh`, headscale-скрипты для `data.external`.

`README.md` — полный текст статьи, H1: **Отказоустойчивость Elasticsearch: Chaos Mesh, потеря зоны и Rally**. Таблицы результатов — плейсхолдеры до прогона.

## Проверка стенда

После apply и join в tailnet: `https://headscale.<PIP>.sslip.io/health`; `tailscale status`; три ноды `a/b/d`; ES 3 пода, health green, шарды по зонам; Kibana и Grafana по `*.<internal-nlb>.sslip.io` без Ingress basic auth; SSH на Rally по внутреннему IP; Rally достукивается до NLB `:9200` без TLS/пароля.

Нагрузка: ingest `geoshape` завершается; `_count` согласован с треком; mixed стартует, id-лог пишется.

Опыты — ручной прогон, не CI.

## Реализация

Стенд хаоса (ECK, Chaos Mesh, Rally, статья) уже в репозитории.

Доступ через Headscale (этот документ, правки 2026-09-19): после утверждения — план реализации (writing-plans), затем код. Implementation Headscale не начинать без отдельного плана и явного «да» на план.
