variable "folder_id" {
  type        = string
  description = "Yandex Cloud folder id"
}

variable "kibana_ingress_password" {
  type        = string
  description = "Пароль basic auth для Ingress Kibana"
  sensitive   = true
}
