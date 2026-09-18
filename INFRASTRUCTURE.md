# Развёртывание инфраструктуры: Terraform

Yandex Managed Kubernetes 1.33, три node group (по одной preemptible-ноде 8 vCPU / 16 ГБ HDD в `ru-central1-a`/`b`/`d`), ноды без публичных IP, NAT-шлюз, Traefik, VM Rally в `ru-central1-e`. Статья — в [README.md](README.md).

Service account: `elastic-chaos-monkey`.

## Traefik

`terraform apply` ставит Traefik (`monitoring.tf`): 3 реплики, LoadBalancer со статическим публичным IP `yandex_vpc_address.ingress`. Grafana и Kibana — `*.<IP>.sslip.io`.

## VictoriaMetrics K8s Stack

Terraform пишет `vmks-values.yaml` из [vmks-values.yaml.tftpl](vmks-values.yaml.tftpl) (`vmks-values.yaml` в `.gitignore`):

- Grafana 3 реплики, Ingress Traefik, `grafana.<IP>.sslip.io`
- VMCluster RF=3, vmstorage 1 vCPU / 2 ГиБ / HDD 30 ГиБ
- vmalert и alertmanager выключены
- scrape-job и recording-правила control-plane Yandex Managed K8s выключены

После apply стек ставится helm CLI — команда в [README.md](README.md).

## Rally VM

`rally-vm.tf`: Ubuntu, 8 vCPU / 16 ГБ, HDD 100 ГиБ, публичный IP, зона `e`. Cloud-init ставит `esrally` в venv пользователя `ubuntu`.

## Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), `yc init`
- Terraform >= 1.3
- kubectl, Helm >= 3
- `~/.ssh/id_ed25519.pub` для Rally VM
- `htpasswd` (apache2-utils) для Ingress basic auth Kibana

## Запуск

```bash
terraform init
terraform apply
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --external --force
kubectl get nodes
```
