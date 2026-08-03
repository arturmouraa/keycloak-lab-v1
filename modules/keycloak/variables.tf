terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace"      {}
variable "hostname"       {}
variable "kube_context"   {}
variable "admin_user"     {}
variable "admin_password" { sensitive = true }
variable "db_host"        {}
variable "db_port"        { default = 5432 }
variable "db_name"        {}
variable "db_secret_name" {}

# --- Realm import ---
variable "enable_realm_import" {
  description = "Whether to provision a realm via a KeycloakRealmImport CR"
  default     = true
}

variable "realm_name" {
  description = "Name of the realm to import"
  default     = "demo"
}

variable "realm_client_id" {
  description = "Client ID to create inside the realm"
  default     = "demo-client"
}

variable "realm_client_redirect_uris" {
  description = "Allowed redirect URIs for the sample client"
  type        = list(string)
  default     = ["*"]
}
