provider "yandex" {
  folder_id = var.folder_id
}

provider "helm" {
  kubernetes = {
    host                   = yandex_kubernetes_cluster.elastic_chaos.master[0].external_v4_endpoint
    cluster_ca_certificate = yandex_kubernetes_cluster.elastic_chaos.master[0].cluster_ca_certificate
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["k8s", "create-token"]
      command     = "yc"
    }
  }
}
