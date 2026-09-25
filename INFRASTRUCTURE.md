# Развёртывание инфраструктуры: Terraform

Два Yandex Managed Kubernetes 1.33 в одной VPC: `elastic` (ноды 8 vCPU / 16 ГБ) и `app` (ноды 2 vCPU / 4 ГБ). По одной preemptible-ноде HDD в `ru-central1-a`/`b`/`d`, без публичного IP. Egress приватных подсетей — один NAT Gateway. Публичный IP только у Headscale VM. Входа ingress-nginx нет, вход — Traefik.

Service account: `elastic-chaos-monkey`.

## Сеть

Подсети `10.0.1.0/24` (`a`), `10.0.2.0/24` (`b`), `10.0.3.0/24` (`d`) общие. Подсеть Headscale `10.0.0.0/24` без route table. Подсети `10.0.4.0/24` нет.

Reserved internal IP в подсети `a`: Traefik `elastic` `10.0.1.33`, Traefik `app` `10.0.1.34`, `vminsert` `10.0.1.35`.

## Headscale

`headscale-vm.tf`: Ubuntu, 2 vCPU / 4 ГБ, HDD 20 ГиБ, preemptible, зона `a`. Единственный публичный IP. Headscale **0.29.3**, Tailscale **1.102.4**, subnet router на `10.0.1.0/24`–`10.0.3.0/24`.

## Traefik

Chart **41.6.0**, 3 реплики, internal NLB. Кластер `elastic`: `traefik-elastic-values.yaml`, хосты Kibana и Elasticsearch. Кластер `app`: `traefik-app-values.yaml`, Grafana. Ingress-nginx не ставить.

## VictoriaMetrics

Только кластер `app`, namespace `vmks`, chart **0.92.1**. Grafana 1 реплика на `10.0.1.34`. VMCluster RF=3, vmstorage HDD 30 ГиБ. Control-plane scrape и recording-правила выключены. `vminsert` публикуется Service `vminsert-nlb` на `10.0.1.35:8480`. vmagent кластера `elastic` пишет туда remote write, не в vmagent `app`.

## Изоляция зоны

Пустой SG `zone-isolation`. `lifecycle.ignore_changes` на `security_group_ids` у всех шести node group. Переключение только `./scripts/isolate-zone.sh` / `./scripts/restore-zone.sh`. State: `.state/zone-isolate.env`.

Isolate ставит пустой SG на node group этой зоны в обоих кластерах. `disable-zones` — только NLB Traefik кластера `elastic` и NLB `vminsert`. На кластере `app` `disable-zones` нет. VM остаётся `RUNNING`.

Restore возвращает сохранённые SG и делает `enable-zones` на оба NLB.

Перед первым прогоном `./scripts/verify-ng-sg-swap.sh` для каждой изолируемой node group в её kubectl-контексте. `VERDICT: RECREATE` — isolate/restore не использовать.

`disable-zones` не чаще раза в 2 минуты на один NLB.

## Требования

- yc CLI, Terraform >= 1.3, kubectl, Helm >= 3, Tailscale, `jq`, `curl`, `envsubst`
- `~/.ssh/id_ed25519.pub` для Headscale VM

## Запуск

```bash
export TF_VAR_folder_id=<folder id>
terraform init
terraform apply
sudo tailscale up --login-server=$(terraform output -raw headscale_url) \
  --auth-key=$(terraform output -raw headscale_laptop_preauth) \
  --accept-routes --force-reauth
eval "$(terraform output -raw elastic_credentials_command)"
eval "$(terraform output -raw app_credentials_command)"
```
