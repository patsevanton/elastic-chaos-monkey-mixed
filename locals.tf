locals {
  folder_id  = var.folder_id
  network_id = yandex_vpc_network.elastic_chaos.id

  subnet_public_id   = yandex_vpc_subnet.elastic_chaos_public.id
  subnet_public_zone = yandex_vpc_subnet.elastic_chaos_public.zone
  subnet_a_id        = yandex_vpc_subnet.elastic_chaos_a.id
  subnet_b_id        = yandex_vpc_subnet.elastic_chaos_b.id
  subnet_d_id   = yandex_vpc_subnet.elastic_chaos_d.id
  subnet_a_zone = yandex_vpc_subnet.elastic_chaos_a.zone
  subnet_b_zone = yandex_vpc_subnet.elastic_chaos_b.zone
  subnet_d_zone = yandex_vpc_subnet.elastic_chaos_d.zone

  ingress_ip         = yandex_vpc_address.ingress.external_ipv4_address[0].address
  traefik_elastic_ip = yandex_vpc_address.traefik.internal_ipv4_address[0].address
  traefik_app_ip     = yandex_vpc_address.traefik_app.internal_ipv4_address[0].address
  vminsert_ip        = yandex_vpc_address.vminsert.internal_ipv4_address[0].address
  headscale_fqdn     = "headscale.${local.ingress_ip}.sslip.io"
}
