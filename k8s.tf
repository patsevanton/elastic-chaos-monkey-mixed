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
  name       = "elastic"
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

    public_ip = true
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

resource "yandex_kubernetes_node_group" "elastic_master_a" {
  name        = "elastic-master-a"
  description = "Elasticsearch master in ru-central1-a"
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

resource "yandex_kubernetes_node_group" "elastic_master_b" {
  name        = "elastic-master-b"
  description = "Elasticsearch master in ru-central1-b"
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

resource "yandex_kubernetes_node_group" "elastic_master_d" {
  name        = "elastic-master-d"
  description = "Elasticsearch master in ru-central1-d"
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

resource "yandex_kubernetes_node_group" "elastic_data_a" {
  name        = "elastic-data-a"
  description = "Elasticsearch data in ru-central1-a"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 2
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
      memory = 16
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

resource "yandex_kubernetes_node_group" "elastic_data_b" {
  name        = "elastic-data-b"
  description = "Elasticsearch data in ru-central1-b"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 2
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
      memory = 16
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

resource "yandex_kubernetes_node_group" "elastic_data_d" {
  name        = "elastic-data-d"
  description = "Elasticsearch data in ru-central1-d"
  cluster_id  = yandex_kubernetes_cluster.elastic_chaos.id
  version     = "1.33"

  scale_policy {
    fixed_scale {
      size = 2
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
      memory = 16
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

output "elastic_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.elastic_chaos.id} --external --force --context-name elastic"
}

output "elastic_cluster_external_ip" {
  description = "Внешний IP API master кластера elastic"
  value       = yandex_kubernetes_cluster.elastic_chaos.master[0].external_v4_address
}

output "nlb_subnet_id" {
  description = "Подсеть a для internal NLB"
  value       = local.subnet_a_id
}

output "zone_isolation_sg_id" {
  description = "ID пустого Security Group для изоляции зоны"
  value       = yandex_vpc_security_group.zone_isolation.id
}

