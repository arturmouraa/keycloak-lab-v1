variable "namespace"    {}
variable "kube_context" {}

variable "db_name" {
  default = "keycloak"
}

variable "db_user" {
  default = "keycloak"
}

variable "db_password" {
  default   = "keycloak"
  sensitive = true
}

variable "storage_size" {
  description = "Size of the PostgreSQL PersistentVolumeClaim"
  default     = "1Gi"
}
