locals {
  vmks_values = templatefile("${path.module}/vmks-values.yaml.tftpl", {
    ingress_ip = local.traefik_app_ip
  })
  traefik_elastic_values = templatefile("${path.module}/traefik-values.yaml.tftpl", {
    nlb_subnet_id = local.subnet_a_id
    traefik_ip    = local.traefik_elastic_ip
  })
  traefik_app_values = templatefile("${path.module}/traefik-values.yaml.tftpl", {
    nlb_subnet_id = local.subnet_a_id
    traefik_ip    = local.traefik_app_ip
  })
  chaos_mesh_elastic_values = templatefile("${path.module}/chaos-mesh-values.yaml.tftpl", {
    ingress_ip = local.traefik_elastic_ip
  })
  chaos_mesh_app_values = templatefile("${path.module}/chaos-mesh-values.yaml.tftpl", {
    ingress_ip = local.traefik_app_ip
  })
}

resource "local_file" "write_vmks_values" {
  content         = local.vmks_values
  filename        = "${path.module}/vmks-values.yaml"
  file_permission = "0644"
}

resource "local_file" "write_traefik_elastic_values" {
  content         = local.traefik_elastic_values
  filename        = "${path.module}/traefik-elastic-values.yaml"
  file_permission = "0644"
}

resource "local_file" "write_traefik_app_values" {
  content         = local.traefik_app_values
  filename        = "${path.module}/traefik-app-values.yaml"
  file_permission = "0644"
}

resource "local_file" "write_chaos_mesh_elastic_values" {
  content         = local.chaos_mesh_elastic_values
  filename        = "${path.module}/chaos-mesh-elastic-values.yaml"
  file_permission = "0644"
}

resource "local_file" "write_chaos_mesh_app_values" {
  content         = local.chaos_mesh_app_values
  filename        = "${path.module}/chaos-mesh-app-values.yaml"
  file_permission = "0644"
}

output "grafana_url" {
  description = "URL Grafana через Traefik кластера app"
  value       = "http://grafana.${local.traefik_app_ip}.sslip.io"
}

output "kibana_url" {
  description = "URL Kibana через Traefik кластера elastic"
  value       = "http://kibana.${local.traefik_elastic_ip}.sslip.io"
}

output "elastic_url" {
  description = "URL Elasticsearch через Traefik кластера elastic"
  value       = "http://elastic.${local.traefik_elastic_ip}.sslip.io"
}

output "chaos_dashboard_url" {
  description = "URL Chaos Mesh Dashboard кластера elastic"
  value       = "http://chaos-dashboard.${local.traefik_elastic_ip}.sslip.io"
}

output "kibana_user" {
  description = "Логин Kibana (пользователь elastic)"
  value       = "elastic"
}

output "traefik_elastic_ip" {
  value = local.traefik_elastic_ip
}

output "traefik_app_ip" {
  value = local.traefik_app_ip
}

output "vminsert_ip" {
  value = local.vminsert_ip
}

output "grafana_admin_password_command" {
  description = "Команда для получения пароля admin Grafana"
  value       = "kubectl --context app -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo"
}

output "kibana_elastic_password_command" {
  description = "Команда для получения пароля пользователя elastic в Kibana"
  value       = "kubectl --context elastic -n elastic get secret elastic-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo"
}
