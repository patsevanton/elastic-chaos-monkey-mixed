resource "yandex_vpc_network" "elastic_chaos" {
  name      = "elastic-chaos-vpc"
  folder_id = var.folder_id
}

resource "yandex_vpc_gateway" "nat" {
  folder_id = var.folder_id
  name      = "elastic-chaos-nat"

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  folder_id  = var.folder_id
  name       = "elastic-chaos-rt-nat"
  network_id = yandex_vpc_network.elastic_chaos.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_subnet" "elastic_chaos_a" {
  folder_id      = var.folder_id
  name           = "elastic-chaos-a"
  v4_cidr_blocks = ["10.0.1.0/24"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "elastic_chaos_d" {
  folder_id      = var.folder_id
  name           = "elastic-chaos-d"
  v4_cidr_blocks = ["10.0.3.0/24"]
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

# Третья локация регионального мастера managed-kubernetes: зона b выведена
# из эксплуатации, поэтому мастер размещается в e. Рабочих node group в e нет.
resource "yandex_vpc_subnet" "elastic_chaos_e" {
  folder_id      = var.folder_id
  name           = "elastic-chaos-e"
  v4_cidr_blocks = ["10.0.4.0/24"]
  zone           = "ru-central1-e"
  network_id     = yandex_vpc_network.elastic_chaos.id
  route_table_id = yandex_vpc_route_table.rt.id
}

