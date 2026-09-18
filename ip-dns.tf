resource "yandex_vpc_address" "ingress" {
  name = "elastic-chaos-ingress-pip"
  external_ipv4_address {
    zone_id = yandex_vpc_subnet.elastic_chaos_a.zone
  }
}
