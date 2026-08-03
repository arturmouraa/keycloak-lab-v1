terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "kube_context" {}

variable "namespace" {
  description = "Namespace for the Elastic stack (Elasticsearch, Kibana, Agents)"
  default     = "elastic-stack"
}

variable "eck_version" {
  description = "ECK operator version"
  default     = "3.4.0"
}

variable "stack_version" {
  description = "Elastic Stack version (Elasticsearch/Kibana/Agent)"
  default     = "9.4.3"
}

variable "es_node_count" {
  description = "Number of Elasticsearch data/master-eligible nodes (keep at 1 for Docker Desktop). If set to 2 or more, also set enable_voting_only_node = true to avoid split-brain risk in master elections."
  default     = 1
}

variable "enable_voting_only_node" {
  description = "Add a 3rd, master-eligible-only (voting_only) Elasticsearch node. Recommended whenever es_node_count = 2, since an even number of master-eligible nodes can't safely reach quorum if one goes down. Holds no data/ingest role."
  default     = false
}

variable "es_voting_only_memory" {
  description = "Memory request/limit for the voting-only node (deliberately small — no data/query load)"
  default     = "1Gi"
}

variable "es_voting_only_storage_size" {
  description = "PVC size for the voting-only node (small — used only for cluster state, not shard data)"
  default     = "2Gi"
}

variable "es_memory" {
  description = "Memory request/limit for each Elasticsearch node"
  default     = "2Gi"
}

variable "es_storage_size" {
  description = "PVC size for each Elasticsearch node"
  default     = "5Gi"
}

variable "kibana_memory" {
  description = "Memory request/limit for Kibana"
  default     = "1Gi"
}

variable "enable_external_fleet" {
  description = "Expose Fleet Server outside the cluster via a MetalLB LoadBalancer Service, so Elastic Agents running on bare-metal hosts, VMs, or other clusters can enroll and check in directly."
  default     = false
}

variable "external_fleet_host" {
  description = "Hostname or IP external agents will use to reach Fleet Server (e.g. a DNS name pointing at the LoadBalancer IP, or the IP itself). Added to Kibana's Fleet Server hosts list so generated enrollment tokens use a reachable URL. Required when enable_external_fleet = true."
  default     = ""
}

variable "external_fleet_load_balancer_ip" {
  description = "Optional static IP (from your MetalLB pool) to pin Fleet Server's external LoadBalancer Service to, via the metallb.universe.tf/loadBalancerIPs annotation. Leave empty to let MetalLB assign any free IP from the pool."
  default     = ""
}

# --- Optional exposure of Kibana through the NGINX gateway ---
variable "enable_kibana_route" {
  description = "Expose Kibana via the shared NGINX gateway (TLS terminated at gateway, HTTP to Kibana)"
  default     = false
}

variable "kibana_hostname" {
  description = "External hostname for Kibana (must match a gateway listener + cert SAN)"
  default     = "kibana.local"
}

variable "gateway_name" {
  description = "Name of the Gateway to attach the Kibana route to"
  default     = "keycloak-gateway"
}

variable "gateway_namespace" {
  description = "Namespace of the Gateway to attach the routes to"
  default     = "keycloak"
}

# --- Optional exposure of the Elasticsearch API through the NGINX gateway ---
variable "enable_es_route" {
  description = "Expose the Elasticsearch API via the shared gateway (TLS terminated at gateway, HTTP to ES). Disables ES self-signed HTTP TLS."
  default     = false
}

variable "es_hostname" {
  description = "External hostname for the Elasticsearch API (must match a gateway listener + cert SAN)"
  default     = "elasticsearch.local"
}

# --- Optional exposure of Fleet Server through the NGINX gateway ---
variable "enable_fleet_route" {
  description = "Expose Fleet Server via the shared gateway (TLS terminated at gateway, HTTP to Fleet). Disables Fleet self-signed HTTP TLS."
  default     = false
}

variable "fleet_hostname" {
  description = "External hostname for Fleet Server (gateway listener SAN, or the direct-TLS cert SAN)"
  default     = "fleet.local"
}

# --- Fleet L4 fallback: dedicated LB serving a cert-manager cert on :8220 ---
variable "enable_fleet_direct_tls" {
  description = "Serve a cert-manager cert (fleet-tls secret) directly on Fleet's HTTPS :8220 LoadBalancer instead of fronting Fleet with the gateway. Mutually exclusive with enable_fleet_route."
  default     = false
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer used to issue the Fleet cert (direct-TLS or the LE proxy)"
  default     = ""
}

# --- Fleet Let's Encrypt via a TLS-terminating reverse proxy (Option B) ---
variable "enable_fleet_le_proxy" {
  description = "Deploy an nginx TLS-terminating reverse proxy that presents a Let's Encrypt cert for fleet_hostname and re-encrypts to Fleet's self-signed :8220. Fleet stays stock."
  default     = false
}

variable "fleet_le_proxy_load_balancer_ip" {
  description = "MetalLB IP for the Fleet LE proxy Service (point fleet_hostname DNS here). Empty = auto-assign."
  default     = ""
}
