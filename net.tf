resource "yandex_vpc_network" "elastic_chaos" {
  name      = "elastic-chaos-vpc"
  folder_id = local.folder_id
}

resource "yandex_vpc_gateway" "nat" {
  folder_id   = local.folder_id
  name        = "elastic-chaos-nat-gw"
  description = "NAT gateway for private subnets egress"

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  folder_id  = local.folder_id
  name       = "elastic-chaos-rt-nat"
  network_id = yandex_vpc_network.elastic_chaos.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_subnet" "elastic_chaos_a" {
  folder_id      = local.folder_id
  name           = "elastic-chaos-a"
  v4_cidr_blocks = ["10.0.1.0/24"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "elastic_chaos_b" {
  folder_id      = local.folder_id
  name           = "elastic-chaos-b"
  v4_cidr_blocks = ["10.0.2.0/24"]
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "elastic_chaos_d" {
  folder_id      = local.folder_id
  name           = "elastic-chaos-d"
  v4_cidr_blocks = ["10.0.3.0/24"]
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "elastic_chaos_e" {
  folder_id      = local.folder_id
  name           = "elastic-chaos-e"
  v4_cidr_blocks = ["10.0.4.0/24"]
  zone           = "ru-central1-e"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}
