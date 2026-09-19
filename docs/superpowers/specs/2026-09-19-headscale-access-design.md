# Доступ к стенду через Headscale

Дата: 2026-09-19  
Репозиторий: `elastic-chaos-monkey-mixed`  
Дополняет: [2026-09-18-elastic-chaos-monkey-mixed-design.md](2026-09-18-elastic-chaos-monkey-mixed-design.md)

## Цель

После `terraform apply` k8s API, Grafana/Kibana (Traefik) и Rally недоступны с ноутбука: публичные адреса режутся или их нет у нод. Нужен единственный вход в VPC — Headscale. С ноутбука в tailnet видны внутренние IP: API master, internal NLB Traefik, Rally SSH.

Публичные IP снимаются у k8s master, Traefik и Rally. В интернет смотрит только Headscale VM.

## Вне скоупа

- Headscale в Kubernetes.
- Caddy или Traefik на Headscale VM.
- Tailscale-клиент на нодах k8s и на Rally.
- Policy / ACL Headscale.
- Публичные Traefik, k8s master, Rally.
- Смена версии Kubernetes (остаётся 1.33).

## Решения

- Отдельная preemptible VM в `ru-central1-a`, не в k8s.
- На той же VM: сервер Headscale + Tailscale-клиент как subnet router на подсети `10.0.1.0/24`–`10.0.4.0/24`.
- HTTPS без reverse proxy: встроенный ACME HTTP-01 Headscale.
- Hostname: `headscale.<PIP>.sslip.io`.
- Embedded DERP на этой VM; карта DERP Tailscale Inc. не подключается (`derp.urls: []`).
- Регистрация: preauth keys, без ручного approve узлов.
- Terraform не ходит в k8s API. Traefik и vmks — helm CLI после `tailscale up`.
- SSH на Headscale VM публичный, ключ `~/.ssh/id_ed25519.pub` как у Rally.
- LAN ноутбука `192.168.3.0/24` с VPC `10.0.x` не пересекается; CIDR VPC не сдвигаем.

## Архитектура

### Headscale VM

- Зона `ru-central1-a`, preemptible, HDD.
- **2 vCPU / 4 ГБ / HDD 20 ГиБ**.
- Образ Ubuntu тот же, что Rally: `fd806c8slu9j1pa87msc`.
- Зарезервированный публичный IPv4 (sslip.io не плывёт после stop/start).
- NAT на этой VM нужен: клиенты и Let's Encrypt ходят на публичный IP.

Cloud-init:

- Headscale **0.29.3** (официальный DEB). Клиент Tailscale на ноутбуке и на VM ≥ **1.80.0**.
- `server_url: https://headscale.<PIP>.sslip.io`
- `listen_addr: :443`
- ACME HTTP-01 (`tls_letsencrypt_hostname` = тот же FQDN). SQLite и ключи в `/var/lib/headscale`.
- Embedded DERP включён, `derp.server.ipv4` = публичный IP VM, `derp.urls: []`.
- Пользователь Headscale: `elastic-chaos`.
- Два reusable preauth key, TTL 24 ч: для subnet-router (эта VM) и для ноутбука.
- `tailscaled` на VM: `--login-server=https://headscale.<PIP>.sslip.io --auth-key=<router> --advertise-routes=10.0.1.0/24,10.0.2.0/24,10.0.3.0/24,10.0.4.0/24`. IP forwarding включён. Маршруты: `headscale nodes approve-routes`.
- Ключ ноутбука пишется в файл на VM; Terraform забирает по SSH → sensitive output.

Порты с интернета: `80/tcp`, `443/tcp`, `3478/udp`, `22/tcp`. Отдельный security group не добавляем (дефолт Yandex).

### Kubernetes

- `master.public_ip = false`.
- Ноды без публичного IP, как сейчас.
- Credentials: `yc managed-kubernetes cluster get-credentials --id ... --internal --force`.
- Provider `helm` и `helm_release.traefik` удаляются: приватный API с ноутбука до join в tailnet недоступен.

### Traefik и UI

- Traefik ставится helm CLI, chart **41.6.0** (`oci://ghcr.io/traefik/helm/traefik`).
- 3 реплики, topology spread по зонам — как сейчас.
- Service LoadBalancer **internal**: аннотации `yandex.cloud/load-balancer-type: internal` и `yandex.cloud/subnet-id` = subnet `a`. Без `loadBalancerIP`.
- Ресурс `yandex_vpc_address.ingress` и `time_sleep.wait_lb_release` удаляются.
- Grafana и Kibana: `grafana.<INTERNAL_NLB_IP>.sslip.io` и `kibana.<INTERNAL_NLB_IP>.sslip.io` (внутренний IP Traefik, не публичный).
- `vmks-values.yaml` Terraform на apply не пишет: IP Traefik ещё нет. После появления internal NLB — скрипт из `vmks-values.yaml.tftpl`.
- vmks chart **0.93.0** (команда в AGENTS.md / README). Версия k8s не меняется.

### Rally

- `nat = false`. Исходящий трафик (apt, pip, esrally) — через существующий NAT Gateway и route table подсети `e`.
- SSH: внутренний IP после `tailscale up --accept-routes`.
- Output `rally_public_ip` убирается; остаётся `rally_internal_ip`.

## Потоки данных

```
Ноутбук --HTTPS :443 / STUN :3478 / WireGuard--> Headscale VM (публичный IP)
Ноутбук --WireGuard--> subnet router на Headscale VM --VPC--> 10.0.1.0/24 … 10.0.4.0/24
  → internal API master (kubectl)
  → internal NLB Traefik (Grafana, Kibana)
  → Rally 10.0.4.x:22
Rally --NAT Gateway--> интернет (пакеты, трек nyc_taxis)
Rally --VPC--> internal NLB Elasticsearch :9200
```

Headscale — координатор и DERP, не шлюз сам по себе. В VPC пакеты в `10.0.x` идут, потому что на VM включён Tailscale-клиент с advertise-routes.

## Порядок после apply

1. `terraform apply` — сеть, k8s (приватный API), Rally без NAT, Headscale VM.
2. `terraform output` — публичный IP Headscale, FQDN, preauth ноутбука.
3. На ноутбуке: `tailscale up --login-server=https://headscale.<PIP>.sslip.io --auth-key=... --accept-routes`.
4. `yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force`.
5. Helm Traefik 41.6.0 → взять IP internal NLB.
6. Скрипт render `vmks-values.yaml` и подстановка IP в Ingress Kibana.
7. Helm vmks **0.93.0** (команда из AGENTS.md).
8. Дальше README как сейчас; SSH на Rally — внутренний IP.

## Ошибки и откат

- Пересечение LAN с `10.0.1.0/24`–`10.0.4.0/24`: у автора LAN `192.168.3.0/24` — конфликта нет.
- ACME: `headscale.<PIP>.sslip.io` должен резолвиться в PIP до первого выпуска сертификата.
- Preemptible Headscale: слот < 22 ч. После recreate тот же зарезервированный PIP; если диск новый — новые preauth, ноутбук перелогинить.
- Stop зоны `b` VPN не роняет (VM в `a`).
- Cloud-init Headscale сломался: SSH ключом или serial console Yandex; иначе recreate VM.
- Откат доступа: вернуть `public_ip` master / NAT Rally / публичный Traefik — отдельное решение, в этой задаче не делаем.

## Проверка

- `https://headscale.<PIP>.sslip.io/health`
- `tailscale status`; ping внутреннего IP Rally и адреса API
- `kubectl get nodes`
- Grafana и Kibana по `*.<internal-nlb>.sslip.io` (Kibana — basic auth Ingress)
- SSH на Rally по внутреннему IP; cloud-init доводит esrally в venv
- Rally достугивается до ES internal NLB `:9200`

## Состав изменений

Новое:

- `headscale-vm.tf`
- `cloud-init/headscale.yaml`
- скрипт render `vmks-values.yaml` из tftpl по IP Traefik

Правки:

- `k8s.tf` — `public_ip = false`, credentials `--internal`
- `rally-vm.tf` — `nat = false`, убрать public IP output
- `ip-dns.tf` — зарезервированный IP Headscale вместо ingress PIP; убрать `wait_lb_release`
- `monitoring.tf` — убрать `helm_release.traefik`; не писать vmks-values на apply
- `providers.tf` — убрать provider `helm`
- `locals.tf` — FQDN Headscale; Grafana/Kibana FQDN после Traefik, не из Terraform apply
- `README.md`, `INFRASTRUCTURE.md`, `AGENTS.md` (vmks 0.93.0)

Traefik values — README или скрипт, не Terraform.

## Реализация

После утверждения этого файла — план реализации (writing-plans), затем код. Implementation не начинать из этого spec без отдельного плана и явного «да» на план.
