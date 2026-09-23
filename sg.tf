resource "yandex_vpc_security_group" "zone_isolation" {
  name       = "zone-isolation"
  network_id = yandex_vpc_network.elastic_chaos.id
}
