variable "kubeconfig_path" {
  default = "~/.kube/config"
}

variable "kube_context" {
  default = "docker-desktop"
}

variable "keycloak_namespace" {
  default = "keycloak"
}

variable "gateway_namespace" {
  default = "gateway"
}

variable "keycloak_hostname" {
  description = "Hostname used for Keycloak ingress + TLS cert SAN"
  default     = "keycloak.local"
}

variable "keycloak_admin_user" {
  description = "Initial Keycloak admin username (applied on first start only)"
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Initial Keycloak admin password (applied on first start only)"
  default     = "admin"
  sensitive   = true

  validation {
    condition     = !contains(["", "admin", "password", "changeme", "keycloak", "root", "test"], lower(var.keycloak_admin_password))
    error_message = "keycloak_admin_password looks like a placeholder/weak default — set a real password in terraform.tfvars before applying."
  }
}

variable "postgres_db_name" {
  default = "keycloak"
}

variable "postgres_db_user" {
  default = "keycloak"
}

variable "postgres_db_password" {
  default   = "keycloak"
  sensitive = true

  validation {
    condition     = !contains(["", "admin", "password", "changeme", "keycloak", "postgres", "root", "test"], lower(var.postgres_db_password))
    error_message = "postgres_db_password looks like a placeholder/weak default — set a real password in terraform.tfvars before applying."
  }
}

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

# --- Elastic Cloud on Kubernetes ---
variable "enable_elastic" {
  description = "Whether to deploy Elastic Cloud on Kubernetes (ECK)"
  default     = true
}

variable "elastic_namespace" {
  description = "Namespace for the Elastic stack"
  default     = "elastic-stack"
}

variable "eck_version" {
  description = "ECK operator version"
  default     = "3.4.0"
}

variable "elastic_stack_version" {
  description = "Elastic Stack version (Elasticsearch/Kibana/Agent)"
  default     = "9.4.3"
}

variable "elastic_es_node_count" {
  description = "Number of Elasticsearch data/master-eligible nodes (keep at 1 for Docker Desktop). If set to 2 or more, also set elastic_enable_voting_only_node = true to avoid split-brain risk."
  default     = 1
}

variable "elastic_enable_voting_only_node" {
  description = "Add a 3rd, master-eligible-only (voting_only) Elasticsearch node. Recommended whenever elastic_es_node_count = 2, since two master-eligible nodes can't safely reach quorum if one goes down."
  default     = false
}

variable "elastic_es_voting_only_memory" {
  description = "Memory request/limit for the voting-only node (deliberately small — no data/query load)"
  default     = "1Gi"
}

variable "elastic_es_voting_only_storage_size" {
  description = "PVC size for the voting-only node (small — used only for cluster state, not shard data)"
  default     = "2Gi"
}

variable "elastic_es_memory" {
  description = "Memory request/limit for each Elasticsearch node"
  default     = "2Gi"
}

variable "elastic_es_storage_size" {
  description = "PVC size for each Elasticsearch node"
  default     = "5Gi"
}

variable "elastic_kibana_memory" {
  description = "Memory request/limit for Kibana"
  default     = "1Gi"
}

variable "elastic_enable_external_fleet" {
  description = "Expose Fleet Server outside the cluster via a MetalLB LoadBalancer Service, so Elastic Agents running on bare-metal hosts, VMs, or other clusters can enroll and check in directly."
  default     = false
}

variable "elastic_external_fleet_host" {
  description = "Hostname or IP external agents will use to reach Fleet Server. Required when elastic_enable_external_fleet = true."
  default     = ""
}

variable "elastic_external_fleet_load_balancer_ip" {
  description = "Optional static IP (from your MetalLB pool) to pin Fleet Server's external LoadBalancer Service to. Leave empty to let MetalLB assign any free IP."
  default     = ""
}

variable "expose_kibana_via_gateway" {
  description = "Expose Kibana through the NGINX gateway at elastic_kibana_hostname (only applies when enable_elastic = true)"
  default     = true
}

variable "elastic_kibana_hostname" {
  description = "Hostname for Kibana via the gateway (add to /etc/hosts, becomes a TLS SAN)"
  default     = "kibana.local"
}

# --- Expose Elasticsearch API through the gateway ---
variable "expose_es_via_gateway" {
  description = "Expose the Elasticsearch HTTP API through the NGINX gateway at elastic_es_hostname (only applies when enable_elastic = true). SECURITY: this publishes a datastore endpoint — protect it with strong Elasticsearch credentials and, ideally, network restrictions."
  default     = false
}

variable "elastic_es_hostname" {
  description = "Hostname for the Elasticsearch API via the gateway (becomes a TLS SAN). Requires disabling ES self-signed HTTP TLS so the gateway terminates TLS instead."
  default     = "elasticsearch.local"
}

# --- Expose Fleet Server through the gateway ---
variable "expose_fleet_via_gateway" {
  description = "Expose Fleet Server through the NGINX gateway at elastic_fleet_hostname (only applies when enable_elastic = true). NOTE: Fleet agent check-in is long-polling over HTTP/2; fronting it with an L7 gateway can need tuning. A dedicated L4 LoadBalancer (enable_external_fleet) is the more robust option."
  default     = false
}

variable "elastic_fleet_hostname" {
  description = "Hostname for Fleet Server via the gateway (becomes a TLS SAN). Requires disabling Fleet self-signed HTTP TLS."
  default     = "fleet.local"
}

# --- Fleet L4 fallback (dedicated LoadBalancer + real cert, no gateway) ---
# NOTE: not viable with an ACME/Let's Encrypt issuer — Fleet Server requires a
# cert secret containing ca.crt, which ACME certs don't populate. Left for a
# private-CA issuer that does emit ca.crt. For LE, use enable_fleet_le_proxy.
variable "enable_fleet_direct_tls" {
  description = "Serve a cert-manager cert directly on Fleet's :8220 LoadBalancer. Only works with an issuer that populates ca.crt (NOT Let's Encrypt/ACME). For LE, use enable_fleet_le_proxy instead."
  default     = false
}

# --- Fleet Let's Encrypt via a TLS-terminating reverse proxy (Option B) ---
variable "enable_fleet_le_proxy" {
  description = "Put a small nginx TLS-terminating reverse proxy in front of Fleet Server: it presents a Let's Encrypt cert for elastic_fleet_hostname and re-encrypts to Fleet's stock self-signed :8220. Fleet stays untouched/healthy; external agents get a publicly-trusted endpoint. Point elastic_fleet_hostname DNS at fleet_le_proxy_load_balancer_ip. Requires enable_lets_encrypt/cert-manager."
  default     = false
}

variable "fleet_le_proxy_load_balancer_ip" {
  description = "MetalLB IP for the Fleet LE proxy's LoadBalancer Service. Point elastic_fleet_hostname DNS here. Leave empty to let MetalLB assign one."
  default     = ""
}

# --- TLS / Let's Encrypt ---
variable "enable_lets_encrypt" {
  description = "Issue gateway TLS certs via cert-manager + Let's Encrypt instead of the built-in self-signed CA. Requires cert-manager and the ClusterIssuer installed by ../proxmox-k8s (enable_cert_manager=true), and PUBLIC Cloudflare-managed hostnames (not .local)."
  default     = false
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer to use when enable_lets_encrypt = true. Use letsencrypt-staging while testing, letsencrypt-prod once certs issue cleanly. Matches the `cluster_issuer` output from ../proxmox-k8s."
  default     = "letsencrypt-staging"
}

# --- Bare-metal / MetalLB ---
variable "gateway_load_balancer_ip" {
  description = "Pin the NGINX gateway's LoadBalancer IP (MetalLB). Leave empty on Docker Desktop. On Proxmox set to the MetalLB pool IP that /etc/hosts points at."
  default     = ""
}

# --- kube-state-metrics ---
variable "enable_kube_state_metrics" {
  description = "Whether to install kube-state-metrics"
  default     = true
}

variable "kube_state_metrics_namespace" {
  description = "Namespace for kube-state-metrics"
  default     = "kube-system"
}

variable "kube_state_metrics_chart_version" {
  description = "kube-state-metrics Helm chart version (prometheus-community)"
  default     = "5.27.1"
}
