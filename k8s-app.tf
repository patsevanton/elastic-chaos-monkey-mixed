resource "yandex_kubernetes_cluster" "app" {
  name       = "app"
  folder_id  = local.folder_id
  network_id = local.network_id

  master {
    version = "1.33"
    regional {
      region = "ru-central1"

      location {
        zone      = local.subnet_a_zone
        subnet_id = local.subnet_a_id
      }

      location {
        zone      = local.subnet_b_zone
        subnet_id = local.subnet_b_id
      }

      location {
        zone      = local.subnet_d_zone
        subnet_id = local.subnet_d_id
      }
    }

    public_ip = false
  }

  service_account_id      = yandex_iam_service_account.elastic_chaos_monkey.id
  node_service_account_id = yandex_iam_service_account.elastic_chaos_monkey.id
  release_channel         = "STABLE"

  depends_on = [
    time_sleep.wait_sa,
    time_sleep.wait_lb_release,
  ]
}

resource "yandex_kubernetes_node_group" "app_a" {
  name        = "app-a"
  description = "Worker in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.app.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_a_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [local.subnet_a_id]
    }

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}

resource "yandex_kubernetes_node_group" "app_b" {
  name        = "app-b"
  description = "Worker in ru-central1-b"
  cluster_id  = yandex_kubernetes_cluster.app.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_b_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [local.subnet_b_id]
    }

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}

resource "yandex_kubernetes_node_group" "app_d" {
  name        = "app-d"
  description = "Worker in ru-central1-d"
  cluster_id  = yandex_kubernetes_cluster.app.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_d_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [local.subnet_d_id]
    }

    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }

  lifecycle {
    ignore_changes = [instance_template[0].network_interface[0].security_group_ids]
  }
}

output "app_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.app.id} --internal --force --context-name app"
}
