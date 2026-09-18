resource "yandex_compute_instance" "rally" {
  name                      = "elastic-chaos-rally"
  platform_id               = "standard-v3"
  zone                      = local.subnet_e_zone
  allow_stopping_for_update = true

  resources {
    cores  = 8
    memory = 16
  }

  boot_disk {
    initialize_params {
      image_id = "fd806c8slu9j1pa87msc"
      size     = 100
      type     = "network-hdd"
    }
  }

  network_interface {
    subnet_id = local.subnet_e_id
    nat       = true
  }

  metadata = {
    ssh-keys  = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
    user-data = file("${path.module}/cloud-init/rally.yaml")
  }
}

output "rally_public_ip" {
  description = "Публичный IP VM esrally (SSH)"
  value       = yandex_compute_instance.rally.network_interface[0].nat_ip_address
}

output "rally_internal_ip" {
  description = "Внутренний IP VM esrally"
  value       = yandex_compute_instance.rally.network_interface[0].ip_address
}
