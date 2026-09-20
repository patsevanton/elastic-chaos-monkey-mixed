# Развёртывание инфраструктуры: Terraform

Yandex Managed Kubernetes 1.33, три node group (по одной preemptible-ноде 8 vCPU / 16 ГБ HDD в `ru-central1-a`/`b`/`d`), ноды без публичных IP, NAT-шлюз, Headscale VM, Traefik helm CLI (internal NLB), VM Rally в `ru-central1-e` без NAT. Статья — в [README.md](README.md).

Service account: `elastic-chaos-monkey`.

## Headscale

`headscale-vm.tf`: Ubuntu, 2 vCPU / 4 ГБ, HDD 20 ГиБ, preemptible, зона `a`. Единственный публичный IP стенда — `yandex_vpc_address.ingress`. Headscale **0.29.3**, Tailscale **1.102.4**, subnet router на `10.0.1.0/24`–`10.0.4.0/24`. Cloud-init: [cloud-init/headscale.yaml.tftpl](cloud-init/headscale.yaml.tftpl).

## Traefik

На apply Terraform пишет [traefik-values.yaml](traefik-values.yaml) из [traefik-values.yaml.tftpl](traefik-values.yaml.tftpl) (`traefik-values.yaml` в `.gitignore`). После `tailscale up` helm CLI: chart **41.6.0**, `-f traefik-values.yaml` — команда в [README.md](README.md). Grafana и Kibana — `*.<INTERNAL_NLB_IP>.sslip.io`.

## VictoriaMetrics K8s Stack

На apply Terraform пишет [vmks-values.yaml](vmks-values.yaml) из [vmks-values.yaml.tftpl](vmks-values.yaml.tftpl) (`vmks-values.yaml` в `.gitignore`), host Grafana — reserved internal IP Traefik:

- Grafana 3 реплики, Ingress Traefik, `grafana.<INTERNAL_NLB_IP>.sslip.io`
- VMCluster RF=3, vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ
- vmalert и alertmanager выключены
- scrape-job и recording-правила control-plane Yandex Managed K8s выключены

Стек ставится helm CLI **0.93.0** — команда в [README.md](README.md).

## Rally VM

`rally-vm.tf`: Ubuntu, 8 vCPU / 16 ГБ, HDD 100 ГиБ, без публичного IP (`nat = false`), зона `e`. Cloud-init ставит `esrally` в venv пользователя `ubuntu`. SSH — внутренний IP после `tailscale up --accept-routes`.

## Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), `yc init`
- Terraform >= 1.3
- kubectl, Helm >= 3
- Tailscale-клиент на ноутбуке
- `~/.ssh/id_ed25519.pub` для Headscale и Rally VM

## Запуск

```bash
terraform init
terraform apply
tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --internal --force
kubectl get nodes
```
