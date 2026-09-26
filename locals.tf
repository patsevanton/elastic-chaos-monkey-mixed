locals {
  network_id = yandex_vpc_network.elastic_chaos.id

  subnet_a_id   = yandex_vpc_subnet.elastic_chaos_a.id
  subnet_b_id   = yandex_vpc_subnet.elastic_chaos_b.id
  subnet_d_id   = yandex_vpc_subnet.elastic_chaos_d.id
  subnet_a_zone = yandex_vpc_subnet.elastic_chaos_a.zone
  subnet_b_zone = yandex_vpc_subnet.elastic_chaos_b.zone
  subnet_d_zone = yandex_vpc_subnet.elastic_chaos_d.zone

  traefik_app_public_ip     = yandex_vpc_address.traefik_app_public.external_ipv4_address[0].address
  traefik_elastic_public_ip = yandex_vpc_address.traefik_elastic_public.external_ipv4_address[0].address
  traefik_elastic_ip        = yandex_vpc_address.traefik.internal_ipv4_address[0].address
  traefik_app_ip            = yandex_vpc_address.traefik_app.internal_ipv4_address[0].address
  vminsert_ip               = yandex_vpc_address.vminsert.internal_ipv4_address[0].address
}
