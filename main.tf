locals {
  # Expose each Elastic component through the gateway only when Elastic is on
  # AND its toggle is set.
  expose_kibana = var.enable_elastic && var.expose_kibana_via_gateway
  expose_es     = var.enable_elastic && var.expose_es_via_gateway
  expose_fleet  = var.enable_elastic && var.expose_fleet_via_gateway

  fleet_direct_tls = var.enable_elastic && var.enable_fleet_direct_tls
  fleet_le_proxy   = var.enable_elastic && var.enable_fleet_le_proxy
}

# -----------------------------------------------------------------------------
# Config guard — enforces invariants that are documented in variable
# descriptions but were never actually checked, so a bad combination used to
# fail late (mid-apply, or as a silently-wrong deployment) instead of at plan
# time. terraform_data + lifecycle.precondition is used (rather than
# per-variable `validation` blocks) because these checks are cross-variable,
# and cross-variable variable validation needs Terraform >= 1.9 while this
# project targets >= 1.6.
# -----------------------------------------------------------------------------
resource "terraform_data" "config_guard" {
  lifecycle {
    precondition {
      condition     = var.elastic_es_node_count != 2 || var.elastic_enable_voting_only_node
      error_message = "elastic_es_node_count = 2 requires elastic_enable_voting_only_node = true — two master-eligible nodes can't safely reach quorum if one goes down (split-brain risk)."
    }

    precondition {
      condition     = !(local.expose_fleet && local.fleet_direct_tls)
      error_message = "expose_fleet_via_gateway and enable_fleet_direct_tls are mutually exclusive Fleet exposure methods — enable only one."
    }

    precondition {
      condition     = !(local.expose_fleet && local.fleet_le_proxy)
      error_message = "expose_fleet_via_gateway and enable_fleet_le_proxy are mutually exclusive Fleet exposure methods — enable only one."
    }

    precondition {
      condition     = !(local.fleet_direct_tls && local.fleet_le_proxy)
      error_message = "enable_fleet_direct_tls and enable_fleet_le_proxy are mutually exclusive Fleet exposure methods — enable only one."
    }

    precondition {
      condition     = !var.enable_lets_encrypt || var.cluster_issuer != ""
      error_message = "enable_lets_encrypt = true requires cluster_issuer to be set."
    }

    precondition {
      condition     = !(local.fleet_direct_tls || local.fleet_le_proxy) || var.cluster_issuer != ""
      error_message = "enable_fleet_direct_tls / enable_fleet_le_proxy require cluster_issuer to be set (a cert-manager ClusterIssuer)."
    }
  }
}

module "cert" {
  source    = "./modules/cert"
  hostname  = var.keycloak_hostname
  namespace = var.keycloak_namespace

  # Add every gateway-exposed Elastic hostname as a SAN so the single TLS secret
  # backs all their listeners (Kibana, Elasticsearch API, Fleet Server).
  extra_hostnames = concat(
    local.expose_kibana ? [var.elastic_kibana_hostname] : [],
    local.expose_es ? [var.elastic_es_hostname] : [],
    local.expose_fleet ? [var.elastic_fleet_hostname] : [],
  )

  # Let's Encrypt path: issue the cert via cert-manager instead of the built-in
  # self-signed CA. Requires cert-manager + the ClusterIssuer from ../proxmox-k8s,
  # and public (Cloudflare-managed) hostnames.
  use_cert_manager = var.enable_lets_encrypt
  cluster_issuer   = var.cluster_issuer
  kube_context     = var.kube_context
}

module "gateway" {
  source             = "./modules/gateway"
  gateway_namespace  = var.gateway_namespace
  keycloak_namespace = var.keycloak_namespace
  hostname           = var.keycloak_hostname
  tls_secret_name    = module.cert.secret_name
  kube_context       = var.kube_context

  enable_kibana_route = local.expose_kibana
  kibana_hostname     = var.elastic_kibana_hostname

  enable_es_route = local.expose_es
  es_hostname     = var.elastic_es_hostname

  enable_fleet_route = local.expose_fleet
  fleet_hostname     = var.elastic_fleet_hostname

  gateway_load_balancer_ip = var.gateway_load_balancer_ip

  depends_on = [module.cert]
}

module "postgres" {
  source       = "./modules/postgres"
  namespace    = var.keycloak_namespace
  kube_context = var.kube_context
  db_name      = var.postgres_db_name
  db_user      = var.postgres_db_user
  db_password  = var.postgres_db_password

  depends_on = [module.cert] # namespace is created by cert module
}

module "keycloak" {
  source         = "./modules/keycloak"
  namespace      = var.keycloak_namespace
  hostname       = var.keycloak_hostname
  kube_context   = var.kube_context
  admin_user     = var.keycloak_admin_user
  admin_password = var.keycloak_admin_password
  db_host        = module.postgres.host
  db_port        = module.postgres.port
  db_name        = module.postgres.db_name
  db_secret_name = module.postgres.secret_name

  enable_realm_import        = var.enable_realm_import
  realm_name                 = var.realm_name
  realm_client_id            = var.realm_client_id
  realm_client_redirect_uris = var.realm_client_redirect_uris

  depends_on = [module.gateway, module.postgres]
}

# -----------------------------------------------------------------------------
# Elastic Cloud on Kubernetes (independent of the Keycloak stack)
# -----------------------------------------------------------------------------
module "elastic" {
  count  = var.enable_elastic ? 1 : 0
  source = "./modules/elastic"

  kube_context    = var.kube_context
  namespace       = var.elastic_namespace
  eck_version     = var.eck_version
  stack_version   = var.elastic_stack_version
  es_node_count   = var.elastic_es_node_count
  es_memory       = var.elastic_es_memory
  es_storage_size = var.elastic_es_storage_size
  kibana_memory   = var.elastic_kibana_memory

  enable_voting_only_node     = var.elastic_enable_voting_only_node
  es_voting_only_memory       = var.elastic_es_voting_only_memory
  es_voting_only_storage_size = var.elastic_es_voting_only_storage_size

  # Kibana / Elasticsearch / Fleet exposure through the shared gateway
  enable_kibana_route = local.expose_kibana
  kibana_hostname     = var.elastic_kibana_hostname
  enable_es_route     = local.expose_es
  es_hostname         = var.elastic_es_hostname
  enable_fleet_route  = local.expose_fleet
  fleet_hostname      = var.elastic_fleet_hostname
  gateway_name        = "keycloak-gateway"

  # Fleet L4 fallback: dedicated LB + cert-manager cert instead of the gateway
  # (private-CA issuer only). For Let's Encrypt, use the TLS-terminating proxy.
  enable_fleet_direct_tls = var.enable_elastic && var.enable_fleet_direct_tls

  # Fleet Let's Encrypt via nginx TLS-terminating reverse proxy (Option B).
  enable_fleet_le_proxy           = var.enable_elastic && var.enable_fleet_le_proxy
  fleet_le_proxy_load_balancer_ip = var.fleet_le_proxy_load_balancer_ip

  cluster_issuer = var.cluster_issuer

  # Fleet Server exposure to agents outside the cluster
  enable_external_fleet           = var.elastic_enable_external_fleet
  external_fleet_host             = var.elastic_external_fleet_host
  external_fleet_load_balancer_ip = var.elastic_external_fleet_load_balancer_ip
  gateway_namespace   = var.keycloak_namespace

  # The gateway must exist (with its Kibana listeners) before the route attaches.
  depends_on = [module.gateway]
}

# -----------------------------------------------------------------------------
# kube-state-metrics — cluster-level metrics, scraped by the Elastic Agent
# Kubernetes integration (state_* datasets). Independent add-on.
# -----------------------------------------------------------------------------
module "kube_state_metrics" {
  count  = var.enable_kube_state_metrics ? 1 : 0
  source = "./modules/kube-state-metrics"

  namespace        = var.kube_state_metrics_namespace
  create_namespace = var.kube_state_metrics_namespace != "kube-system"
  chart_version    = var.kube_state_metrics_chart_version
}
