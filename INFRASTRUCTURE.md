# Развёртывание инфраструктуры: Terraform

Yandex Managed Kubernetes 1.33, три node group (по одной preemptible-ноде 8 vCPU / 16 ГБ HDD в `ru-central1-a`/`b`/`d`), ноды без публичных IP. Egress приватных подсетей — один Yandex NAT Gateway (`yandex_vpc_gateway` + route table), подсеть Headscale без RT. Traefik helm CLI (internal NLB), VM Rally в `ru-central1-e` без публичного IP. Статья — в [README.md](README.md).

Service account: `elastic-chaos-monkey`.

## Headscale

`headscale-vm.tf`: Ubuntu, 2 vCPU / 4 ГБ, HDD 20 ГиБ, preemptible, зона `a`, подсеть `elastic-chaos-public` (`10.0.0.0/24`) без route table. Единственный публичный IP стенда — `yandex_vpc_address.ingress`. Egress `10.0.1.0/24`–`10.0.4.0/24` — NAT Gateway, не MASQUERADE на Headscale; `ip_forward` только для Tailscale subnet router. Headscale **0.29.3**, Tailscale **1.102.4**, subnet router на те же префиксы. Cloud-init: [cloud-init/headscale.yaml.tftpl](cloud-init/headscale.yaml.tftpl).

## Traefik

На apply Terraform пишет [traefik-values.yaml](traefik-values.yaml) из [traefik-values.yaml.tftpl](traefik-values.yaml.tftpl) (`traefik-values.yaml` в `.gitignore`). После `tailscale up` helm CLI: chart **41.6.0**, `-f traefik-values.yaml` — команда в [README.md](README.md). Reserved internal IP Traefik закреплён в `ip-dns.tf` как `10.0.1.33`, Ingress Grafana, Kibana и Chaos Dashboard — `*.<INTERNAL_NLB_IP>.sslip.io`. Метрики Traefik выдаёт отдельный сервис `traefik-metrics`.

## VictoriaMetrics K8s Stack

На apply Terraform пишет [vmks-values.yaml](vmks-values.yaml) из [vmks-values.yaml.tftpl](vmks-values.yaml.tftpl) (`vmks-values.yaml` в `.gitignore`), host Grafana — reserved internal IP Traefik:

- Grafana 1 реплика, Ingress Traefik, `grafana.<INTERNAL_NLB_IP>.sslip.io`
- VMCluster RF=3, vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ
- vmalert и alertmanager выключены
- scrape-job и recording-правила control-plane Yandex Managed K8s выключены

Стек ставится helm CLI **0.92.1** — команда в [README.md](README.md).

`vmks` содержит SA `chaos-mesh-admin` и Secret с токеном для Chaos Dashboard. Grafana получает этот токен через `secretKeyRef`, устанавливает `chaosmeshorg-datasource` 3.0.0 и provision-ит datasource `Chaos Mesh` для просмотра событий; токен не записывается в Terraform values. Chaos Mesh chart **2.8.4** получает [chaos-mesh-values.yaml](chaos-mesh-values.yaml) из [chaos-mesh-values.yaml.tftpl](chaos-mesh-values.yaml.tftpl): Dashboard Ingress Traefik `chaos-dashboard.10.0.1.33.sslip.io`.

ES NLB `chaos-es-http` использует закреплённый в `ip-dns.tf` reserved internal IP `10.0.1.5`; ECK Service запрашивает его через `loadBalancerIP`. Снаружи кластера к NLB ходит Rally VM, а Kibana/exporter ходят на ClusterIP. При полном `terraform destroy` оба reserved internal IP освобождаются, после `terraform apply` снова запрашиваются по тем же адресам. Текущий `10.0.1.5` занят эфемерным адресом работающего CCM NLB; переход на reserved address выполнять после штатного destroy, не поверх работающего NLB.

## Rally VM

`rally-vm.tf`: Ubuntu, 8 vCPU / 16 ГБ, SSD 150 ГиБ, без публичного IP (`nat = false`), зона `e`, подсеть `10.0.4.0/24`. Benchmark до ES в `10.0.1/2/3` внутри VPC, без NAT. Исходящий (apt, pip) — NAT Gateway. SSH — внутренний IP после `tailscale up --accept-routes`.

## Изоляция зоны b

Terraform: `sg.tf` — пустой SG `zone-isolation` (deny all), output `zone_isolation_sg_id`. У `k8s_node_group_b` `lifecycle.ignore_changes` на `instance_template[0].network_interface[0].security_group_ids`: `terraform apply` не должен возвращать SG во время эксперимента. Переключение изоляции — только CLI, state до изменений в `.state/zone-b-isolate.env` (`.state/` в `.gitignore`). Механика isolate/restore — в [README.md](README.md).

NLB id. Оба CCM-ных NLB (`chaos-es-http`, `traefik`) скрипты находят по `listeners[].address` = ingress IP сервиса: аннотации `yandex.cloud/load-balancer-id` у Service нет.

Check отвала зоны. `disable_zone_statuses` + `zone_shifted` у target'а ноды. Не `status=HEALTHY`: health check проходит и при отключённой зоне.

Первый прогон на кластере. `./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)"`. `VERDICT: HOT-SWAP` — работаем как есть. `VERDICT: RECREATE` — `node-group update` пересоздаёт узел, значит это не network partition: isolate/restore переписать на `yc compute instance update-network-interface`.

Лимит ЯО. `disable-zones` не чаще одного раза в 2 минуты на один NLB.

## Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), `yc init`
- Terraform >= 1.3
- kubectl, Helm >= 3
- Tailscale-клиент на ноутбуке
- `~/.ssh/id_ed25519.pub` для Headscale и Rally VM
- `jq`, `python3`, `curl` (скрипты `scripts/`)

## Запуск

```bash
export TF_VAR_folder_id=<folder id>
terraform init
terraform apply
sudo tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes --force-reauth
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force
kubectl get nodes
```
