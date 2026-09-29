# TODO

- Настроить скрейпинг Cilium-метрик (`cilium-agent` :9962, `cilium-operator` :9963) и label `cluster` для дашборда "Cilium Node Connectivity Latency" — пока deferred. Cilium как CNI уже включён через `network_implementation { cilium {} }` в `k8s.tf` и `k8s-app.tf`.