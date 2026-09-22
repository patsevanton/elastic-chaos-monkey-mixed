resource "yandex_iam_service_account" "elastic_chaos_monkey" {
  folder_id = local.folder_id
  name      = "elastic-chaos-monkey"
}

resource "yandex_resourcemanager_folder_iam_member" "elastic_chaos_monkey_editor" {
  folder_id = local.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.elastic_chaos_monkey.id}"
}


resource "time_sleep" "wait_sa" {
  create_duration = "20s"
  depends_on = [
    yandex_iam_service_account.elastic_chaos_monkey,
    yandex_resourcemanager_folder_iam_member.elastic_chaos_monkey_editor,
  ]
}

resource "yandex_kubernetes_cluster" "elastic_chaos" {
  name       = "elastic-chaos"
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

  # Зависимость от ожидания применения IAM-ролей.
  # При destroy кластер должен удалиться ДО time_sleep.wait_lb_release,
  # чтобы CCM успел снять internal NLB Traefik (и ES).
  depends_on = [
    time_sleep.wait_sa,
    time_sleep.wait_lb_release,
  ]
}

resource "yandex_kubernetes_node_group" "k8s_node_group_a" {
  name        = "elastic-chaos-a"
  description = "Worker in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
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
      cores  = 8
      memory = 24
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }
}

resource "yandex_kubernetes_node_group" "k8s_node_group_b" {
  name        = "elastic-chaos-b"
  description = "Worker in ru-central1-b (AZ-outage target)"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
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
      cores  = 8
      memory = 24
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }
}

resource "yandex_kubernetes_node_group" "k8s_node_group_d" {
  name        = "elastic-chaos-d"
  description = "Worker in ru-central1-d"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
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
      cores  = 8
      memory = 24
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }

    scheduling_policy {
      preemptible = true
    }
  }
}

output "k8s_cluster_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.elastic_chaos.id} --internal --force"
}

output "k8s_cluster_id" {
  description = "ID кластера"
  value       = yandex_kubernetes_cluster.elastic_chaos.id
}

output "nlb_subnet_id" {
  description = "Подсеть для internal NLB Elasticsearch"
  value       = local.subnet_a_id
}

