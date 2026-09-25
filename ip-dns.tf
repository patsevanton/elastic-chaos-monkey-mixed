resource "yandex_vpc_address" "ingress" {
  name = "elastic-chaos-ingress-pip"
  external_ipv4_address {
    zone_id = yandex_vpc_subnet.elastic_chaos_public.zone
  }
}

resource "yandex_vpc_address" "traefik" {
  name = "elastic-traefik-internal"
  internal_ipv4_address {
    subnet_id = yandex_vpc_subnet.elastic_chaos_a.id
    address   = "10.0.1.33"
  }
}

resource "yandex_vpc_address" "traefik_app" {
  name = "app-traefik-internal"
  internal_ipv4_address {
    subnet_id = yandex_vpc_subnet.elastic_chaos_a.id
    address   = "10.0.1.34"
  }
}

resource "yandex_vpc_address" "vminsert" {
  name = "app-vminsert-internal"
  internal_ipv4_address {
    subnet_id = yandex_vpc_subnet.elastic_chaos_a.id
    address   = "10.0.1.35"
  }
}

# Пауза при terraform destroy после удаления кластера.
# CCM должен успеть снять internal NLB Traefik (и ES), иначе сеть/подсети
# и reserved internal IP удаляются слишком рано.
# Порядок destroy: cluster -> time_sleep (пауза) -> адреса.
resource "time_sleep" "wait_lb_release" {
  destroy_duration = "60s"

  depends_on = [
    yandex_vpc_address.ingress,
    yandex_vpc_address.traefik,
    yandex_vpc_address.traefik_app,
    yandex_vpc_address.vminsert,
  ]
}
