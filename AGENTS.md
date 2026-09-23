# Правила

- Зону `b` ломать только `./scripts/isolate-zone-b.sh`, чинить только `./scripts/restore-zone-b.sh`. Power-off VM (`yc compute instance stop`) — не наш сценарий.
- `terraform apply` для переключения изоляции не применять: SG переключается CLI, иначе apply «чинит» эксперимент. Контракт — в [INFRASTRUCTURE.md](INFRASTRUCTURE.md).
- Перед первым прогоном на кластере — `./scripts/verify-ng-sg-swap.sh "$(terraform output -raw zone_isolation_sg_id)"`. При `VERDICT: RECREATE` isolate/restore не использовать, переписать на `yc compute instance update-network-interface`.
- `disable-zones` не чаще раза в 2 минуты на NLB — при retry выдержать паузу.

# Установка VictoriaMetrics

```bash
helm upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-values.yaml
```
