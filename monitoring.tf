locals {
  vmks_values = templatefile("${path.module}/vmks-values.yaml.tftpl", {
    ingress_ip = local.traefik_ip
  })
  traefik_values = templatefile("${path.module}/traefik-values.yaml.tftpl", {
    nlb_subnet_id = local.subnet_a_id
    traefik_ip    = local.traefik_ip
  })
}

resource "local_file" "write_vmks_values" {
  content         = local.vmks_values
  filename        = "${path.module}/vmks-values.yaml"
  file_permission = "0644"
}

resource "local_file" "write_traefik_values" {
  content         = local.traefik_values
  filename        = "${path.module}/traefik-values.yaml"
  file_permission = "0644"
}

output "grafana_url" {
  description = "URL Grafana (FQDN из internal IP Traefik через sslip.io)"
  value       = "http://grafana.${local.traefik_ip}.sslip.io"
}

output "kibana_url" {
  description = "URL Kibana (FQDN из internal IP Traefik через sslip.io)"
  value       = "http://kibana.${local.traefik_ip}.sslip.io"
}

output "traefik_ip" {
  description = "Reserved internal IP Traefik NLB"
  value       = local.traefik_ip
}

output "grafana_admin_password_command" {
  description = "Команда для получения пароля admin Grafana"
  value       = "kubectl -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo"
}
