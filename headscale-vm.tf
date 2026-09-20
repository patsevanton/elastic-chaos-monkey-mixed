resource "yandex_compute_instance" "headscale" {
  name                      = "elastic-chaos-headscale"
  platform_id               = "standard-v3"
  zone                      = local.subnet_public_zone
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = "fd806c8slu9j1pa87msc"
      size     = 20
      type     = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id      = local.subnet_public_id
    nat            = true
    nat_ip_address = yandex_vpc_address.ingress.external_ipv4_address[0].address
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
    user-data = templatefile("${path.module}/cloud-init/headscale.yaml.tftpl", {
      headscale_fqdn = local.headscale_fqdn
      ingress_ip     = local.ingress_ip
    })
  }

  provisioner "file" {
    source      = "${path.module}/headscale_0.29.3_linux_amd64.deb"
    destination = "/tmp/headscale.deb"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.network_interface[0].nat_ip_address
    private_key = file("~/.ssh/id_ed25519")
  }
}

data "external" "headscale_service_ready" {
  program = ["bash", "${path.module}/scripts/wait-headscale-ready.sh"]

  query = {
    ip = yandex_compute_instance.headscale.network_interface[0].nat_ip_address
  }

  depends_on = [yandex_compute_instance.headscale]
}

data "external" "headscale_laptop_preauth" {
  program = ["bash", "${path.module}/scripts/fetch-headscale-preauth.sh"]

  query = {
    ip = yandex_compute_instance.headscale.network_interface[0].nat_ip_address
  }

  depends_on = [
    yandex_compute_instance.headscale,
    data.external.headscale_service_ready,
  ]
}

output "headscale_public_ip" {
  description = "Публичный IP Headscale VM"
  value       = yandex_compute_instance.headscale.network_interface[0].nat_ip_address
}

output "headscale_url" {
  description = "URL Headscale (ACME / login-server)"
  value       = "https://${local.headscale_fqdn}"
}

output "headscale_login_command" {
  description = "Команда tailscale up для ноутбука (с preauth-ключом)"
  value       = "sudo tailscale up --login-server=https://${local.headscale_fqdn} --auth-key=$(terraform output -raw headscale_laptop_preauth) --accept-routes --force-reauth"
}

output "headscale_laptop_preauth" {
  description = "Reusable preauth-ключ ноутбука (TTL 24h)"
  value       = data.external.headscale_laptop_preauth.result.key
  sensitive   = true
}
