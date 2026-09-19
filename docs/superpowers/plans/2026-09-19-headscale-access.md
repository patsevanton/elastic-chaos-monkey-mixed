# План: доступ к стенду через Headscale

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** После `terraform apply` ноутбук ходит в k8s API, Grafana/Kibana и Rally только через Headscale; публичный IP только у Headscale VM (`yandex_vpc_address.ingress`).

**Architecture:** Headscale 0.29.3 на preemptible VM в `ru-central1-a` (встроенный ACME, embedded DERP) + `tailscaled` subnet router на `10.0.1.0/24`–`10.0.4.0/24`. k8s `public_ip = false`, Rally `nat = false`, Traefik/vmks — helm CLI после `tailscale up`. Reserved IP и `wait_lb_release` переиспользуются.

**Tech stack:** Terraform (yandex, time), cloud-init, Headscale 0.29.3, Tailscale ≥ 1.80.0, Helm Traefik 41.6.0, victoria-metrics-k8s-stack 0.93.0.

**Spec:** [docs/superpowers/specs/2026-09-18-elastic-chaos-monkey-mixed-design.md](../specs/2026-09-18-elastic-chaos-monkey-mixed-design.md)

---

## File structure

Создать:

- `headscale-vm.tf`
- `cloud-init/headscale.yaml.tftpl`
- `scripts/render-vmks-values.sh`
- `scripts/install-traefik.sh`

Изменить:

- `k8s.tf`, `rally-vm.tf`, `ip-dns.tf`, `monitoring.tf`, `providers.tf`, `versions.tf`, `locals.tf`, `variables.tf`
- `manifests/ingress/kibana.yaml`
- `scripts/apply-eck.sh`
- `vmks-values.yaml.tftpl` (имя переменной IP)
- `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`

Удалить логику: `helm_release.traefik`, provider `helm`, `local_file.write_vmks_values` на apply, `kibana_ingress_password`, Middleware basic auth.

---

### Task 1: Terraform — приватный API, Rally без NAT, без Helm

**Files:** `k8s.tf`, `rally-vm.tf`, `providers.tf`, `versions.tf`, `variables.tf`

- [ ] В `k8s.tf` у master: `public_ip = false`.
- [ ] Output credentials: `--internal --force` вместо `--external`.
- [ ] Комментарий `depends_on = time_sleep.wait_lb_release`: пауза destroy, чтобы CCM снял **internal** NLB Traefik (и ES), не «адрес ingress занят публичным LB».
- [ ] В `rally-vm.tf`: `nat = false`. Удалить output `rally_public_ip`. Оставить `rally_internal_ip`.
- [ ] В `providers.tf`: удалить provider `helm`.
- [ ] В `versions.tf`: удалить `helm` и `local` из `required_providers`, если после Task 3 `local_file` больше нет.
- [ ] В `variables.tf`: удалить `kibana_ingress_password`.

---

### Task 2: Reserved IP на Headscale, `wait_lb_release` оставить

**Files:** `ip-dns.tf`, `locals.tf`

- [ ] Ресурс `yandex_vpc_address.ingress` **не удалять**. Имя можно оставить `elastic-chaos-ingress-pip` (переиспользование). Зона `ru-central1-a`.
- [ ] `time_sleep.wait_lb_release` **не удалять**: `destroy_duration = "60s"`, `depends_on = [yandex_vpc_address.ingress]`. Обновить комментарий: кластер destroy → пауза → дальше IP/сеть; CCM успевает снять internal NLB. IP теперь на Headscale VM, не на Traefik.
- [ ] В `locals.tf`:
  - `ingress_ip` = адрес `yandex_vpc_address.ingress` (это PIP Headscale).
  - `headscale_fqdn` = `headscale.${local.ingress_ip}.sslip.io`
  - Убрать `grafana_fqdn` / `kibana_fqdn` из Terraform (IP Traefik неизвестен до helm).

---

### Task 3: Headscale VM + cloud-init

**Files:** `headscale-vm.tf` (новый), `cloud-init/headscale.yaml.tftpl` (новый), `monitoring.tf`

- [ ] VM `yandex_compute_instance.headscale`:
  - name `elastic-chaos-headscale`, `platform_id = standard-v3`, зона `local.subnet_a_zone`
  - 2 vCPU / 4 ГБ, HDD 20 ГиБ, image `fd806c8slu9j1pa87msc`
  - `scheduling_policy { preemptible = true }`
  - `network_interface`: subnet `a`, `nat = true`, `nat_ip_address = yandex_vpc_address.ingress.external_ipv4_address[0].address`
  - `ssh-keys` = `ubuntu:${file("~/.ssh/id_ed25519.pub")}`
  - `user-data` = `templatefile` cloud-init с `headscale_fqdn` и `ingress_ip`
- [ ] Cloud-init (Ubuntu 22.04):
  - sysctl: `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`
  - поставить Headscale **0.29.3** DEB с GitHub releases (`headscale_0.29.3_linux_amd64.deb`)
  - поставить Tailscale (официальный repo, клиент ≥ 1.80.0)
  - `/etc/headscale/config.yaml`: `server_url` / `tls_letsencrypt_hostname` = FQDN; `listen_addr: 0.0.0.0:443`; ACME HTTP-01; `tls_letsencrypt_listen: :80`; SQLite `/var/lib/headscale`; `derp.server.enabled: true`, `ipv4: <PIP>`, `derp.urls: []`
  - `systemctl enable --now headscale`
  - дождаться `/health` по HTTPS (с ретраями: сертификат ACME не мгновенный)
  - `headscale users create elastic-chaos`
  - два reusable preauth TTL 24h: router и laptop; ключ laptop в `/var/lib/headscale/laptop-preauth.key` (режим 0640, группа ubuntu или файл, который Terraform читает по SSH)
  - `tailscale up --login-server=https://<FQDN> --authkey=<router> --advertise-routes=10.0.1.0/24,10.0.2.0/24,10.0.3.0/24,10.0.4.0/24 --accept-dns=false`
  - `headscale nodes approve-routes` для четырёх префиксов (после появления ноды; ретраи)
- [ ] Terraform: remote-exec или `ssh` provisioner **не обязателен**, если ключ на диске. Output `headscale_laptop_preauth` — `sensitive`, читать файл по SSH (`ssh ubuntu@PIP cat ...`) через `terraform_data` + `local-exec`, либо документировать `ssh ... cat` в README, если чтение из Terraform хрупко. Предпочтение: README + output FQDN/PIP; ключ забирать командой из README (меньше гонок cloud-init vs apply). **Решение плана:** apply не ждёт ключ; в README команда `ssh ubuntu@$(terraform output -raw headscale_public_ip) sudo cat /var/lib/headscale/laptop-preauth.key`.
- [ ] Outputs: `headscale_public_ip`, `headscale_url` (`https://${local.headscale_fqdn}`), `headscale_login_command` (шаблон `tailscale up --login-server=... --accept-routes`).
- [ ] `monitoring.tf`: удалить `locals.vmks_values`, `local_file.write_vmks_values`, `helm_release.traefik`, outputs `grafana_url` / `kibana_url` (или заменить текстом «после helm Traefik, см. README»). Оставить `grafana_admin_password_command`.

---

### Task 4: Скрипты Traefik / vmks / ECK, Ingress без basic auth

**Files:** `scripts/install-traefik.sh`, `scripts/render-vmks-values.sh`, `scripts/apply-eck.sh`, `manifests/ingress/kibana.yaml`, `vmks-values.yaml.tftpl`

- [ ] `install-traefik.sh`: helm Traefik **41.6.0**, namespace `traefik`, 3 реплики, topology spread как в нынешнем `monitoring.tf`; Service LoadBalancer; annotations `yandex.cloud/load-balancer-type: internal`, `yandex.cloud/subnet-id` = `terraform output -raw nlb_subnet_id`. Без `loadBalancerIP`. Image registry `ghcr.io` / `traefik/traefik` как сейчас.
- [ ] `render-vmks-values.sh`: IP = `kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`; `sed`/`envsubst` в `vmks-values.yaml.tftpl`. Переименовать плейсхолдер tftpl: `ingress_public_ip` → `ingress_ip` (это internal NLB).
- [ ] `kibana.yaml`: удалить Middleware `kibana-auth` и annotation `router.middlewares`. Host по-прежнему `kibana.INGRESS_IP.sslip.io` (подстановка internal IP).
- [ ] `apply-eck.sh`: убрать `KIBANA_INGRESS_PASSWORD`, `htpasswd`, secret `kibana-basic-auth`. `INGRESS_IP` — IP Traefik svc, не `terraform output ingress_ip` (тот теперь Headscale). `NLB_SUBNET_ID` — как сейчас.

---

### Task 5: Документация

**Files:** `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md`

- [ ] README шаг 0: apply → SSH за ключом → `tailscale up --login-server=https://headscale.<PIP>.sslip.io --auth-key=... --accept-routes` → `yc ... --internal --force` → `./scripts/install-traefik.sh` → `./scripts/render-vmks-values.sh` → helm vmks **0.93.0**. Grafana/Kibana URL из internal IP. SSH Rally на `rally_internal_ip`. Убрать htpasswd, публичный Rally, `--external`, Traefik из apply.
- [ ] INFRASTRUCTURE.md: Headscale VM, единственный публичный IP, Traefik helm CLI internal, vmks 0.93.0, Rally без NAT.
- [ ] AGENTS.md: `--version 0.93.0`.

---

### Task 6: Проверка (без полного apply в CI)

- [ ] `terraform fmt -check` / `terraform validate` (нужен `terraform init` после удаления helm).
- [ ] Гrep: нет `--external`, `helm_release`, `kibana_ingress_password`, `basicAuth`, `nat = true` у Rally, `public_ip = true`.
- [ ] Гrep: есть `public_ip = false`, Headscale 0.29.3, Traefik 41.6.0, vmks 0.93.0, `wait_lb_release`, `yandex_vpc_address.ingress` на Headscale VM.
- [ ] Ручной прогон после merge — по README, не в этом плане.

---

## Порядок реализации

Task 1 → 2 → 3 → 4 → 5 → 6. Коммиты по правилам репозитория (существительные), только если пользователь явно попросит коммитить код.

Не начинать код без явного «да» на этот план.
