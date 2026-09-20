# Установка VictoriaMetrics

```bash
helm upgrade --install vmks \
    oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
    --namespace vmks --create-namespace \
    --wait --version 0.92.1 --timeout 15m \
    -f vmks-values.yaml
```
