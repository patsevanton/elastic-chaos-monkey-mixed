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
    nat       = false
  }

  metadata = {
    ssh-keys  = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
    user-data = file("${path.module}/cloud-init/rally.yaml")
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /home/ubuntu/.rally/benchmarks/data/nyc_taxis"]
  }

  provisioner "file" {
    source      = "${path.module}/documents.json.bz2"
    destination = "/home/ubuntu/.rally/benchmarks/data/nyc_taxis/documents.json.bz2"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.network_interface[0].ip_address
    private_key = file("~/.ssh/id_ed25519")
    timeout     = "30m"
  }
}

output "rally_internal_ip" {
  description = "Внутренний IP VM esrally"
  value       = yandex_compute_instance.rally.network_interface[0].ip_address
}
