variable "gateway_namespace"  {}
variable "keycloak_namespace" {}
variable "hostname"           {}
variable "tls_secret_name"    {}
variable "kube_context"       {}

# --- Optional Kibana exposure ---
variable "enable_kibana_route" {
  description = "Add HTTPS/HTTP listeners for Kibana to the Gateway"
  default     = false
}

variable "kibana_hostname" {
  description = "Hostname for the Kibana listener (must be a SAN on the TLS cert)"
  default     = "kibana.local"
}

# --- Optional Elasticsearch API exposure ---
variable "enable_es_route" {
  description = "Add HTTPS/HTTP listeners for the Elasticsearch API to the Gateway"
  default     = false
}

variable "es_hostname" {
  description = "Hostname for the Elasticsearch listener (must be a SAN on the TLS cert)"
  default     = "elasticsearch.local"
}

# --- Optional Fleet Server exposure ---
variable "enable_fleet_route" {
  description = "Add HTTPS/HTTP listeners for Fleet Server to the Gateway"
  default     = false
}

variable "fleet_hostname" {
  description = "Hostname for the Fleet Server listener (must be a SAN on the TLS cert)"
  default     = "fleet.local"
}

variable "gateway_load_balancer_ip" {
  description = "Pin the gateway LoadBalancer IP via the MetalLB annotation (bare-metal). Empty = let the platform assign (Docker Desktop)."
  default     = ""
}
