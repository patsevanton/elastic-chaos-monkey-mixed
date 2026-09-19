resource "yandex_vpc_address" "ingress" {
  name = "elastic-chaos-ingress-pip"
  external_ipv4_address {
    zone_id = yandex_vpc_subnet.elastic_chaos_a.zone
  }
}

# Пауза перед удалением публичного IP-адреса при terraform destroy.
# LoadBalancer, создаваемый cloud-controller-manager через Service Traefik,
# освобождает адрес не мгновенно после удаления кластера/helm-релиза — без паузы
# yandex_vpc_address.ingress падает с ошибкой "Address in use".
# Порядок destroy: helm_release -> cluster -> time_sleep (пауза) -> yandex_vpc_address.ingress.
resource "time_sleep" "wait_lb_release" {
  destroy_duration = "60s"

  depends_on = [
    yandex_vpc_address.ingress,
  ]
}
