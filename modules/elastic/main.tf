# -----------------------------------------------------------------------------
# Elastic Cloud on Kubernetes (ECK)
# Official install: https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s
#
# Deploys, via the ECK operator:
#   - Elasticsearch
#   - Kibana (pre-configured for Fleet)
#   - Fleet Server (Agent in fleet mode, fleetServerEnabled)
#   - Elastic Agent (Agent in fleet mode, enrolled into Fleet Server)
#
# Same pattern as the rest of the project: operator + CRDs and all custom
# resources are applied via kubectl local-exec to avoid the Kubernetes
# provider's plan-time CRD validation problem. Plain core resources (the
# namespace) use the native provider.
# -----------------------------------------------------------------------------

locals {
  eck_crds_url     = "https://download.elastic.co/downloads/eck/${var.eck_version}/crds.yaml"
  eck_operator_url = "https://download.elastic.co/downloads/eck/${var.eck_version}/operator.yaml"

  # In-cluster service DNS names the operator creates for the stack.
  es_http_host    = "elasticsearch-es-http.${var.namespace}.svc"
  fleet_http_host = "fleet-server-agent-http.${var.namespace}.svc"

  # --- Elasticsearch nodeSets ---
  # "default" holds data + is master-eligible. With es_node_count >= 2, master
  # quorum math needs a 3rd master-eligible node to avoid split-brain — that's
  # the optional voting-only nodeSet below (master-eligible, never holds data,
  # exists purely to break ties in master elections).
  es_default_nodeset = {
    name  = "default"
    count = var.es_node_count
    config = {
      # Required on Docker Desktop: avoids the vm.max_map_count requirement
      "node.store.allow_mmap" = false
    }
    podTemplate = {
      spec = {
        containers = [
          {
            name = "elasticsearch"
            resources = {
              requests = { memory = var.es_memory, cpu = "500m" }
              limits   = { memory = var.es_memory, cpu = "2" }
            }
          }
        ]
      }
    }
    volumeClaimTemplates = [
      {
        metadata = { name = "elasticsearch-data" }
        spec = {
          accessModes = ["ReadWriteOnce"]
          resources   = { requests = { storage = var.es_storage_size } }
          # storageClassName left unset → cluster default (Docker Desktop "hostpath")
        }
      }
    ]
  }

  es_voting_only_nodeset = {
    name  = "voting-only"
    count = 1
    config = {
      "node.store.allow_mmap" = false
      # Master-eligible tie-breaker only — never holds data/ingest/other roles.
      "node.roles" = ["master", "voting_only", "remote_cluster_client"]
    }
    podTemplate = {
      spec = {
        containers = [
          {
            name = "elasticsearch"
            resources = {
              requests = { memory = var.es_voting_only_memory, cpu = "250m" }
              limits   = { memory = var.es_voting_only_memory, cpu = "1" }
            }
          }
        ]
      }
    }
    volumeClaimTemplates = [
      {
        metadata = { name = "elasticsearch-data" }
        spec = {
          accessModes = ["ReadWriteOnce"]
          resources   = { requests = { storage = var.es_voting_only_storage_size } }
        }
      }
    ]
  }

  es_node_sets = concat(
    [local.es_default_nodeset],
    var.enable_voting_only_node ? [local.es_voting_only_nodeset] : []
  )

  # --- Elasticsearch ---
  elasticsearch = {
    apiVersion = "elasticsearch.k8s.elastic.co/v1"
    kind       = "Elasticsearch"
    metadata   = { name = "elasticsearch", namespace = var.namespace }
    spec = merge(
      {
        version  = var.stack_version
        nodeSets = local.es_node_sets
      },
      # Fronted by the gateway via a BackendTLSPolicy: KEEP ES's self-signed TLS
      # so all in-cluster ES traffic stays encrypted (Kibana, Fleet, agents are
      # unaffected). We only ensure the internal service DNS is a SAN, so NGF can
      # verify the backend cert when it re-encrypts to ES on the es. route.
      var.enable_es_route ? {
        http = { tls = { selfSignedCertificate = { subjectAltNames = [{ dns = local.es_http_host }] } } }
      } : {}
    )
  }

  # Kibana config. When exposed through the gateway we disable Kibana's own
  # self-signed TLS (gateway terminates TLS and talks HTTP to Kibana, mirroring
  # the Keycloak setup) and set the public base URL so links are generated
  # against the external https hostname.
  kibana_base_config = {
    "xpack.fleet.agents.elasticsearch.hosts" = ["https://${local.es_http_host}:9200"]
    "xpack.fleet.agents.fleet_server.hosts"  = local.fleet_server_hosts
    "xpack.fleet.packages" = [
      { name = "system", version = "latest" },
      { name = "elastic_agent", version = "latest" },
      { name = "fleet_server", version = "latest" },
      { name = "kubernetes", version = "latest" },
    ]
    "xpack.fleet.agentPolicies" = [
      {
        name               = "Fleet Server on ECK policy"
        id                 = "eck-fleet-server"
        namespace          = "default"
        is_managed         = true
        monitoring_enabled = ["logs", "metrics"]
        unenroll_timeout   = 900
        inactivity_timeout = 1800
        package_policies = [
          { name = "fleet_server-1", id = "fleet_server-1", package = { name = "fleet_server" } }
        ]
      },
      {
        name               = "Elastic Agent on ECK policy"
        id                 = "eck-agent"
        namespace          = "default"
        is_managed         = true
        monitoring_enabled = ["logs", "metrics"]
        unenroll_timeout   = 900
        inactivity_timeout = 1800
        package_policies = [
          { name = "system-1", id = "system-1", package = { name = "system" } },
          { name = "kubernetes-1", id = "kubernetes-1", package = { name = "kubernetes" } },
        ]
      },
    ]
  }

  kibana_proxy_config = var.enable_kibana_route ? {
    "server.publicBaseUrl" = "https://${var.kibana_hostname}"
  } : {}

  # --- Kibana ---
  kibana = {
    apiVersion = "kibana.k8s.elastic.co/v1"
    kind       = "Kibana"
    metadata   = { name = "kibana", namespace = var.namespace }
    spec = merge(
      {
        version          = var.stack_version
        count            = 1
        elasticsearchRef = { name = "elasticsearch" }
        config           = merge(local.kibana_base_config, local.kibana_proxy_config)
        podTemplate = {
          spec = {
            containers = [
              {
                name = "kibana"
                resources = {
                  requests = { memory = var.kibana_memory, cpu = "500m" }
                  limits   = { memory = var.kibana_memory, cpu = "1" }
                }
              }
            ]
          }
        }
      },
      # Disable Kibana's self-signed HTTP TLS only when fronted by the gateway
      var.enable_kibana_route ? {
        http = {
          tls = {
            selfSignedCertificate = { disabled = true }
          }
        }
      } : {}
    )
  }

  # --- Fleet Server (Agent in fleet mode) ---
  # By default Fleet Server is reachable only inside the cluster, at
  # fleet_http_host:8220. enable_external_fleet adds a MetalLB LoadBalancer
  # (L4) so external agents can reach it directly; enable_fleet_route fronts it
  # with the shared gateway (L7) at a public hostname instead.
  #
  # When fronted by the gateway, Fleet's self-signed TLS is disabled so it
  # serves HTTP on 8220 — so the in-cluster URL becomes http://, and external
  # agents use the public https gateway URL on 443.
  # In-cluster Fleet URL is http:// only when the gateway path disabled Fleet TLS.
  fleet_internal_scheme = var.enable_fleet_route ? "http" : "https"

  # Agent-facing (advertised) Fleet URLs:
  #  - gateway (L7):      public https on 443 at the hostname
  #  - direct TLS (L4):   public https on 8220 at the hostname (Fleet serves the cert)
  #  - plain external LB: https on 8220 at the given host/IP (ECK self-signed)
  fleet_advertised_hosts = concat(
    var.enable_fleet_route ? ["https://${var.fleet_hostname}"] : [],
    var.enable_fleet_direct_tls ? ["https://${var.fleet_hostname}:8220"] : [],
    var.enable_fleet_le_proxy ? ["https://${var.fleet_hostname}:8220"] : [],
    (var.enable_external_fleet && var.external_fleet_host != "" && !var.enable_fleet_direct_tls && !var.enable_fleet_le_proxy && !var.enable_fleet_route) ? ["https://${var.external_fleet_host}:8220"] : [],
  )
  fleet_server_hosts = concat(
    ["${local.fleet_internal_scheme}://${local.fleet_http_host}:8220"],
    local.fleet_advertised_hosts,
  )

  # spec.http for the Fleet Server Agent, assembled from two concerns that both
  # live under http, so they must be merged into one object:
  #  - service: LoadBalancer override for external L4 exposure
  #  - tls:     gateway path disables self-signed TLS; direct-TLS path installs a
  #             cert-manager cert (fleet-tls); otherwise ECK's self-signed stays.
  fleet_service = var.enable_external_fleet ? {
    service = merge(
      { spec = { type = "LoadBalancer" } },
      var.external_fleet_load_balancer_ip != "" ? {
        metadata = { annotations = { "metallb.universe.tf/loadBalancerIPs" = var.external_fleet_load_balancer_ip } }
      } : {}
    )
  } : {}

  fleet_tls = var.enable_fleet_route ? {
    tls = { selfSignedCertificate = { disabled = true } }
    } : var.enable_fleet_direct_tls ? {
    tls = { certificate = { secretName = "fleet-tls" } }
  } : {}

  fleet_http = merge(local.fleet_service, local.fleet_tls)

  # NOTE on securityContext.runAsUser = 0 below (both this Agent and
  # elastic_agent): this matches Elastic's own official ECK quickstart/recipe
  # manifests for Fleet Server and Elastic Agent, and was a hard requirement
  # before Elastic Stack 7.14 / ECK 2.10 (local state dir ownership on the
  # hostPath/emptyDir volume). Running non-root is possible on this stack
  # version but needs extra wiring (an init container or DaemonSet to chown
  # local state, or moving state to a dedicated emptyDir) that isn't set up
  # here — left as-is rather than changed blind, since it's not testable
  # without a live cluster.
  fleet_server = {
    apiVersion = "agent.k8s.elastic.co/v1alpha1"
    kind       = "Agent"
    metadata   = { name = "fleet-server", namespace = var.namespace }
    spec = merge(
      {
        version            = var.stack_version
        kibanaRef          = { name = "kibana" }
        elasticsearchRefs  = [{ name = "elasticsearch" }]
        mode               = "fleet"
        fleetServerEnabled = true
        policyID           = "eck-fleet-server"
        deployment = {
          replicas = 1
          podTemplate = {
            spec = {
              serviceAccountName           = "fleet-server"
              automountServiceAccountToken = true
              securityContext              = { runAsUser = 0 }
            }
          }
        }
      },
      length(local.fleet_http) > 0 ? { http = local.fleet_http } : {}
    )
  }

  # --- Elastic Agent (Agent in fleet mode, enrolled into Fleet Server) ---
  elastic_agent = {
    apiVersion = "agent.k8s.elastic.co/v1alpha1"
    kind       = "Agent"
    metadata   = { name = "elastic-agent", namespace = var.namespace }
    spec = {
      version        = var.stack_version
      kibanaRef      = { name = "kibana" }
      fleetServerRef = { name = "fleet-server" }
      mode           = "fleet"
      policyID       = "eck-agent"
      daemonSet = {
        podTemplate = {
          spec = {
            serviceAccountName           = "elastic-agent"
            hostNetwork                  = true
            dnsPolicy                    = "ClusterFirstWithHostNet"
            automountServiceAccountToken = true
            securityContext              = { runAsUser = 0 }
          }
        }
      }
    }
  }

  # --- RBAC for Fleet Server ---
  fleet_server_sa = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = "fleet-server", namespace = var.namespace }
  }
  fleet_server_cr = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = "fleet-server-${var.namespace}" }
    rules = [
      { apiGroups = [""], resources = ["pods", "namespaces", "nodes"], verbs = ["get", "watch", "list"] },
      { apiGroups = ["apps"], resources = ["replicasets"], verbs = ["get", "watch", "list"] },
      { apiGroups = ["batch"], resources = ["jobs"], verbs = ["get", "watch", "list"] },
      { apiGroups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["get", "create", "update"] },
    ]
  }
  fleet_server_crb = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "fleet-server-${var.namespace}" }
    subjects   = [{ kind = "ServiceAccount", name = "fleet-server", namespace = var.namespace }]
    roleRef    = { kind = "ClusterRole", name = "fleet-server-${var.namespace}", apiGroup = "rbac.authorization.k8s.io" }
  }

  # --- RBAC for Elastic Agent ---
  elastic_agent_sa = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = "elastic-agent", namespace = var.namespace }
  }
  elastic_agent_cr = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = "elastic-agent-${var.namespace}" }
    rules = [
      {
        apiGroups = [""]
        resources = ["pods", "nodes", "namespaces", "events", "services", "configmaps", "persistentvolumes", "persistentvolumeclaims", "nodes/stats"]
        verbs     = ["get", "watch", "list"]
      },
      { apiGroups = ["events.k8s.io"], resources = ["events"], verbs = ["get", "watch", "list"] },
      { apiGroups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["get", "create", "update"] },
      { apiGroups = ["extensions"], resources = ["replicasets"], verbs = ["get", "list", "watch"] },
      { apiGroups = ["apps"], resources = ["statefulsets", "deployments", "replicasets", "daemonsets"], verbs = ["get", "list", "watch"] },
      { apiGroups = ["batch"], resources = ["jobs", "cronjobs"], verbs = ["get", "list", "watch"] },
      { apiGroups = ["storage.k8s.io"], resources = ["storageclasses"], verbs = ["get", "list", "watch"] },
      { nonResourceURLs = ["/metrics"], verbs = ["get"] },
    ]
  }
  elastic_agent_crb = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "elastic-agent-${var.namespace}" }
    subjects   = [{ kind = "ServiceAccount", name = "elastic-agent", namespace = var.namespace }]
    roleRef    = { kind = "ClusterRole", name = "elastic-agent-${var.namespace}", apiGroup = "rbac.authorization.k8s.io" }
  }

  # --- Optional Kibana routes (attach to the shared gateway, cross-namespace) ---
  kibana_route = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "kibana-route", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "https-kibana"
      }]
      hostnames = [var.kibana_hostname]
      rules = [{
        backendRefs = [{
          group = ""
          kind  = "Service"
          name  = "kibana-kb-http"
          port  = 5601
        }]
      }]
    }
  }
  kibana_redirect = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "kibana-http-redirect", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "http-kibana"
      }]
      hostnames = [var.kibana_hostname]
      rules = [{
        filters = [{
          type            = "RequestRedirect"
          requestRedirect = { scheme = "https", statusCode = 301 }
        }]
      }]
    }
  }

  # --- Optional Elasticsearch API routes ---
  es_route = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "elasticsearch-route", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "https-es"
      }]
      hostnames = [var.es_hostname]
      rules = [{
        backendRefs = [{
          group = ""
          kind  = "Service"
          name  = "elasticsearch-es-http"
          port  = 9200
        }]
      }]
    }
  }
  es_redirect = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "elasticsearch-http-redirect", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "http-es"
      }]
      hostnames = [var.es_hostname]
      rules = [{
        filters = [{
          type            = "RequestRedirect"
          requestRedirect = { scheme = "https", statusCode = 301 }
        }]
      }]
    }
  }

  # BackendTLSPolicy so NGF connects to ES over TLS (re-encrypt) and verifies the
  # ECK self-signed cert against the es-ca ConfigMap + the internal svc hostname.
  es_backendtls_manifest = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "BackendTLSPolicy"
    metadata   = { name = "elasticsearch-backend-tls", namespace = var.namespace }
    spec = {
      targetRefs = [{
        group = ""
        kind  = "Service"
        name  = "elasticsearch-es-http"
      }]
      validation = {
        caCertificateRefs = [{
          group = ""
          kind  = "ConfigMap"
          name  = "es-ca"
        }]
        hostname = local.es_http_host
      }
    }
  })

  # --- Optional Fleet Server routes ---
  fleet_route = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "fleet-route", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "https-fleet"
      }]
      hostnames = [var.fleet_hostname]
      rules = [{
        backendRefs = [{
          group = ""
          kind  = "Service"
          name  = "fleet-server-agent-http"
          port  = 8220
        }]
      }]
    }
  }
  fleet_redirect = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "fleet-http-redirect", namespace = var.namespace }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.gateway_namespace
        sectionName = "http-fleet"
      }]
      hostnames = [var.fleet_hostname]
      rules = [{
        filters = [{
          type            = "RequestRedirect"
          requestRedirect = { scheme = "https", statusCode = 301 }
        }]
      }]
    }
  }

  # Full stack manifest as one multi-document YAML string.
  # Each document is encoded to a YAML string *before* concatenation so both
  # branches of the conditional are list(string) with identical element types
  # (Terraform rejects concatenating tuples whose element object shapes differ).
  base_docs = [
    yamlencode(local.fleet_server_sa),
    yamlencode(local.fleet_server_cr),
    yamlencode(local.fleet_server_crb),
    yamlencode(local.elastic_agent_sa),
    yamlencode(local.elastic_agent_cr),
    yamlencode(local.elastic_agent_crb),
    yamlencode(local.elasticsearch),
    yamlencode(local.kibana),
    yamlencode(local.fleet_server),
    yamlencode(local.elastic_agent),
  ]

  # Gateway routes (Kibana / Elasticsearch / Fleet) are managed by their OWN
  # resource (terraform_data.gateway_routes) rather than being bundled into
  # stack_manifest. This way a route/hostname change never forces a replace of
  # the monolithic stack — which would otherwise tear down Elasticsearch/Kibana.
  gateway_routes_manifest = join("\n---\n", concat(
    var.enable_kibana_route ? [yamlencode(local.kibana_route), yamlencode(local.kibana_redirect)] : [],
    var.enable_es_route ? [yamlencode(local.es_route), yamlencode(local.es_redirect)] : [],
    var.enable_fleet_route ? [yamlencode(local.fleet_route), yamlencode(local.fleet_redirect)] : [],
  ))

  # cert-manager cert (fleet-tls) for the Fleet hostname. Consumed either by the
  # direct-TLS path (private-CA issuer) or by the LE proxy below.
  fleet_cert_manifest = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "fleet-tls", namespace = var.namespace }
    spec = {
      secretName = "fleet-tls"
      dnsNames   = [var.fleet_hostname]
      issuerRef  = { name = var.cluster_issuer, kind = "ClusterIssuer", group = "cert-manager.io" }
    }
  })

  # --- Fleet LE terminator proxy (Option B) -----------------------------------
  # nginx presents the LE cert (fleet-tls) to external agents and re-encrypts to
  # Fleet's stock self-signed :8220. HTTP/2 on the client side, long timeouts for
  # agent long-polling. The internal hop verifies Fleet Server's self-signed
  # cert against the CA published by terraform_data.fleet_server_ca (same
  # pattern as the ES BackendTLSPolicy CA fetch below) rather than trusting it
  # blindly, since this is a network hop like any other inside the cluster.
  fleet_proxy_nginx_conf = <<-EOT
    worker_processes auto;
    error_log /dev/stderr warn;
    events { worker_connections 1024; }
    http {
      access_log /dev/stdout;
      server {
        listen 8220 ssl;
        http2 on;
        ssl_certificate     /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        client_max_body_size 100m;
        location / {
          proxy_pass https://${local.fleet_http_host}:8220;
          proxy_ssl_trusted_certificate /etc/nginx/fleet-ca/ca.crt;
          proxy_ssl_verify on;
          proxy_ssl_verify_depth 2;
          proxy_ssl_name ${local.fleet_http_host};
          proxy_ssl_server_name on;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
          proxy_buffering off;
        }
      }
    }
  EOT

  # Runs nginx and reloads it within ~60s of the mounted cert changing, so
  # cert-manager renewals are picked up without a manual restart.
  fleet_proxy_command = <<-EOT
    nginx -g "daemon off;" &
    NGINX_PID=$!
    LAST=$(md5sum /etc/nginx/tls/tls.crt 2>/dev/null || true)
    while sleep 60; do
      CUR=$(md5sum /etc/nginx/tls/tls.crt 2>/dev/null || true)
      if [ "$CUR" != "$LAST" ]; then echo "cert changed, reloading nginx"; nginx -s reload || true; LAST=$CUR; fi
    done &
    wait $NGINX_PID
  EOT

  fleet_proxy_manifest = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "fleet-le-proxy", namespace = var.namespace }
      data       = { "nginx.conf" = local.fleet_proxy_nginx_conf }
    }),
    yamlencode({
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata   = { name = "fleet-le-proxy", namespace = var.namespace, labels = { app = "fleet-le-proxy" } }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "fleet-le-proxy" } }
        template = {
          metadata = { labels = { app = "fleet-le-proxy" } }
          spec = {
            containers = [{
              name    = "nginx"
              image   = "nginx:1.27-alpine"
              command = ["/bin/sh", "-c", local.fleet_proxy_command]
              ports   = [{ containerPort = 8220, name = "https" }]
              volumeMounts = [
                { name = "conf", mountPath = "/etc/nginx/nginx.conf", subPath = "nginx.conf" },
                { name = "tls", mountPath = "/etc/nginx/tls", readOnly = true },
                { name = "fleet-ca", mountPath = "/etc/nginx/fleet-ca", readOnly = true },
              ]
            }]
            volumes = [
              { name = "conf", configMap = { name = "fleet-le-proxy" } },
              { name = "tls", secret = { secretName = "fleet-tls" } },
              { name = "fleet-ca", configMap = { name = "fleet-server-ca" } },
            ]
          }
        }
      }
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "fleet-le-proxy"
        namespace = var.namespace
        annotations = var.fleet_le_proxy_load_balancer_ip != "" ? {
          "metallb.universe.tf/loadBalancerIPs" = var.fleet_le_proxy_load_balancer_ip
        } : {}
      }
      spec = {
        type     = "LoadBalancer"
        selector = { app = "fleet-le-proxy" }
        ports    = [{ name = "https", port = 8220, targetPort = 8220, protocol = "TCP" }]
      }
    }),
  ])

  stack_manifest = join("\n---\n", local.base_docs)
}

# -----------------------------------------------------------------------------
# Step 1 — Install ECK CRDs (server-side apply avoids the annotation size limit
# that the large ECK CRDs hit with client-side apply)
# -----------------------------------------------------------------------------
resource "terraform_data" "eck_crds" {
  triggers_replace = {
    kube_context = var.kube_context
    eck_version  = var.eck_version
    crds_url     = local.eck_crds_url
  }

  provisioner "local-exec" {
    command = "kubectl --context=${self.triggers_replace.kube_context} apply --server-side -f ${self.triggers_replace.crds_url}"
  }

  # Deleting the ECK CRDs cascades to ALL Elastic custom resources in the cluster.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --context=${self.triggers_replace.kube_context} delete -f ${self.triggers_replace.crds_url} --ignore-not-found"
  }
}

# -----------------------------------------------------------------------------
# Step 2 — Wait for the CRDs we use to be established
# -----------------------------------------------------------------------------
resource "terraform_data" "eck_crds_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    crds_id      = terraform_data.eck_crds.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Established \
        --timeout=120s \
        crd/elasticsearches.elasticsearch.k8s.elastic.co \
        crd/kibanas.kibana.k8s.elastic.co \
        crd/agents.agent.k8s.elastic.co
    EOT
  }

  depends_on = [terraform_data.eck_crds]
}

# -----------------------------------------------------------------------------
# Step 3 — Install the ECK operator (into the elastic-system namespace)
# -----------------------------------------------------------------------------
resource "terraform_data" "eck_operator" {
  triggers_replace = {
    kube_context = var.kube_context
    operator_url = local.eck_operator_url
  }

  provisioner "local-exec" {
    command = "kubectl --context=${self.triggers_replace.kube_context} apply -f ${self.triggers_replace.operator_url}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --context=${self.triggers_replace.kube_context} delete -f ${self.triggers_replace.operator_url} --ignore-not-found"
  }

  depends_on = [terraform_data.eck_crds_ready]
}

# -----------------------------------------------------------------------------
# Step 4 — Wait for the operator StatefulSet to be ready
# -----------------------------------------------------------------------------
resource "terraform_data" "eck_operator_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    operator_id  = terraform_data.eck_operator.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} rollout status \
        statefulset/elastic-operator \
        -n elastic-system \
        --timeout=180s
    EOT
  }

  depends_on = [terraform_data.eck_operator]
}

# -----------------------------------------------------------------------------
# Step 5 — Namespace for the Elastic stack (core resource, native provider)
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "elastic" {
  metadata { name = var.namespace }
}

# -----------------------------------------------------------------------------
# Step 6 — Apply the full stack (Elasticsearch, Kibana, Fleet Server, Elastic
# Agent + RBAC, and optionally the Kibana gateway routes). ECK reconciles the
# inter-resource dependencies itself, so all resources are applied together.
# -----------------------------------------------------------------------------
resource "terraform_data" "elastic_stack" {
  triggers_replace = {
    kube_context        = var.kube_context
    namespace           = var.namespace
    gateway_namespace   = var.gateway_namespace
    enable_kibana_route = tostring(var.enable_kibana_route)
    stack_manifest      = local.stack_manifest
  }

  # base64 round-trip so nothing in the rendered YAML (e.g. a stray single
  # quote in a hostname/var) can break out of the shell string.
  provisioner "local-exec" {
    command = "echo '${base64encode(self.triggers_replace.stack_manifest)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f -"
  }

  # Do NOT tear the stack down on replace. This resource is replaced whenever
  # stack_manifest changes — including something as innocuous as the Kibana
  # publicBaseUrl when the hostname changes. The create step re-applies the
  # manifest idempotently and ECK reconciles in place, so a replace must be a
  # no-op here; deleting Elasticsearch/Kibana would cause an outage (and risks
  # the data PVCs). Real teardown is handled by deleting the elastic namespace
  # (kubernetes_namespace.elastic), which removes all namespaced resources.
  #
  # NOTE: the two cluster-scoped RBAC objects are NOT namespaced and so survive
  # a namespace delete. Remove them manually on full teardown:
  #   kubectl delete clusterrole,clusterrolebinding \
  #     fleet-server-<ns> elastic-agent-<ns> --ignore-not-found
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving Elastic stack in place on replace (namespace teardown removes namespaced resources; see note re: cluster RBAC).'"
  }

  depends_on = [
    terraform_data.eck_operator_ready,
    kubernetes_namespace.elastic,
  ]
}

# -----------------------------------------------------------------------------
# Step 6b — Wait for ECK to generate the "elastic" superuser Secret, then read
# it into Terraform state so it can be exposed as an output. `kubectl apply`
# on the Elasticsearch CR only guarantees the object was accepted — ECK
# creates this Secret asynchronously as it reconciles, so it isn't
# necessarily there yet by the time elastic_stack's apply returns.
# -----------------------------------------------------------------------------
resource "terraform_data" "elastic_password_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"; NS="${var.namespace}"
      for i in $(seq 1 30); do
        VAL=$(kubectl --context "$CTX" -n "$NS" get secret elasticsearch-es-elastic-user \
          -o jsonpath='{.data.elastic}' 2>/dev/null || true)
        [ -n "$VAL" ] && exit 0
        echo "  ...elasticsearch-es-elastic-user secret not ready ($i/30), sleeping 10s"
        sleep 10
      done
      echo "ERROR: elasticsearch-es-elastic-user secret not found after 300s"
      exit 1
    EOT
  }

  depends_on = [terraform_data.elastic_stack]
}

# depends_on defers this read to apply time (after the wait above), rather
# than trying — and failing — to read it during plan on a first-ever apply.
data "kubernetes_secret" "elastic_password" {
  metadata {
    name      = "elasticsearch-es-elastic-user"
    namespace = var.namespace
  }

  depends_on = [terraform_data.elastic_password_ready]
}

# -----------------------------------------------------------------------------
# Step 7 — Gateway routes for Kibana / Elasticsearch / Fleet (separate resource
# on purpose). Kept out of stack_manifest so changing a hostname or route only
# re-applies these HTTPRoutes — it never forces a replace of the Elastic stack.
# Applied when any of the three is fronted by the shared gateway.
# -----------------------------------------------------------------------------
resource "terraform_data" "gateway_routes" {
  count = (var.enable_kibana_route || var.enable_es_route || var.enable_fleet_route) ? 1 : 0

  triggers_replace = {
    kube_context = var.kube_context
    routes_yaml  = local.gateway_routes_manifest
  }

  # base64 round-trip so nothing in the rendered YAML (e.g. a stray single
  # quote in a hostname) can break out of the shell string.
  provisioner "local-exec" {
    command = "echo '${base64encode(self.triggers_replace.routes_yaml)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f -"
  }

  # In-place: a hostname change updates these routes via `kubectl apply` (same
  # object names). No delete on replace, so there's no 404 gap. Real teardown is
  # handled by deleting the elastic namespace, which removes these routes too.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving gateway routes in place on replace; namespace teardown removes them.'"
  }

  depends_on = [terraform_data.elastic_stack]
}

# -----------------------------------------------------------------------------
# Step 7b — Elasticsearch backend TLS. Copies the ECK-generated ES HTTP CA into
# a ConfigMap and applies a BackendTLSPolicy so NGF re-encrypts to ES (keeping
# ES's own TLS on) and verifies its cert — instead of disabling ES TLS. Only
# when ES is exposed through the gateway.
# -----------------------------------------------------------------------------
resource "terraform_data" "es_backend_tls" {
  count = var.enable_es_route ? 1 : 0

  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
    policy       = local.es_backendtls_manifest
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"; NS="${var.namespace}"

      echo "Fetching the ECK Elasticsearch HTTP CA..."
      CA=""
      for i in $(seq 1 30); do
        CA=$(kubectl --context "$CTX" -n "$NS" get secret elasticsearch-es-http-certs-public \
          -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true)
        [ -n "$CA" ] && break
        echo "  ...ES CA not ready ($i/30), sleeping 10s"; sleep 10
      done
      if [ -z "$CA" ]; then echo "ERROR: ES HTTP CA not found"; exit 1; fi

      echo "Publishing es-ca ConfigMap for the BackendTLSPolicy..."
      kubectl --context "$CTX" -n "$NS" create configmap es-ca --from-literal=ca.crt="$CA" \
        --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -

      echo "Applying BackendTLSPolicy for Elasticsearch..."
      printf '%s' '${base64encode(local.es_backendtls_manifest)}' | base64 -d | kubectl --context "$CTX" apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving es-ca / BackendTLSPolicy in place on replace; namespace teardown removes them.'"
  }

  depends_on = [terraform_data.elastic_stack, terraform_data.gateway_routes]
}

# -----------------------------------------------------------------------------
# Step 8 — Fleet L4 fallback certificate. When enable_fleet_direct_tls is set,
# issue a cert-manager cert (fleet-tls) for the Fleet hostname so Fleet serves a
# trusted cert directly on its :8220 LoadBalancer — no gateway involved. This
# avoids the L7 long-polling fragility for agent check-in.
# -----------------------------------------------------------------------------
resource "terraform_data" "fleet_cert" {
  count = (var.enable_fleet_direct_tls || var.enable_fleet_le_proxy) ? 1 : 0

  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
    cert_yaml    = local.fleet_cert_manifest
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"
      if [ -z "${var.cluster_issuer}" ]; then echo "ERROR: cluster_issuer is empty (needs cert-manager)"; exit 1; fi
      echo "Applying Fleet Certificate (fleet-tls) via ${var.cluster_issuer}..."
      printf '%s' '${base64encode(local.fleet_cert_manifest)}' | base64 -d | kubectl --context "$CTX" apply -f -
      kubectl --context "$CTX" -n "${var.namespace}" wait \
        --for=condition=Ready certificate/fleet-tls --timeout=420s || \
        echo "WARNING: fleet-tls not Ready yet; check: kubectl -n ${var.namespace} describe certificate fleet-tls"
    EOT
  }

  # In-place on replace; namespace teardown removes the Certificate + secret.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving fleet-tls Certificate in place; namespace teardown removes it.'"
  }

  depends_on = [kubernetes_namespace.elastic]
}

# -----------------------------------------------------------------------------
# Step 9 — Fleet Server CA, published so the LE proxy (below) can verify the
# internal hop instead of disabling TLS verification. Same pattern as
# es_backend_tls: ECK's self-signed cert secret naming is
# <http-service-name>-certs-public, matching elasticsearch-es-http-certs-public.
# -----------------------------------------------------------------------------
resource "terraform_data" "fleet_server_ca" {
  count = var.enable_fleet_le_proxy ? 1 : 0

  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"; NS="${var.namespace}"

      echo "Fetching the ECK Fleet Server HTTP CA..."
      CA=""
      for i in $(seq 1 30); do
        CA=$(kubectl --context "$CTX" -n "$NS" get secret fleet-server-agent-http-certs-public \
          -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true)
        [ -n "$CA" ] && break
        echo "  ...Fleet Server CA not ready ($i/30), sleeping 10s"; sleep 10
      done
      if [ -z "$CA" ]; then echo "ERROR: Fleet Server HTTP CA not found"; exit 1; fi

      echo "Publishing fleet-server-ca ConfigMap for the LE proxy..."
      kubectl --context "$CTX" -n "$NS" create configmap fleet-server-ca --from-literal=ca.crt="$CA" \
        --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving fleet-server-ca ConfigMap in place; namespace teardown removes it.'"
  }

  depends_on = [terraform_data.elastic_stack]
}

# -----------------------------------------------------------------------------
# Step 10 — Fleet LE terminator proxy (Option B). nginx presents the LE cert and
# re-encrypts to Fleet's stock self-signed :8220, so external agents get a
# publicly-trusted endpoint while Fleet Server stays untouched. Point
# fleet_hostname DNS at the proxy's LoadBalancer IP.
# -----------------------------------------------------------------------------
resource "terraform_data" "fleet_le_proxy" {
  count = var.enable_fleet_le_proxy ? 1 : 0

  triggers_replace = {
    kube_context   = var.kube_context
    namespace      = var.namespace
    proxy_manifest = local.fleet_proxy_manifest
  }

  # base64 round-trip so nothing in the rendered YAML can break out of the
  # shell string.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"
      printf '%s' '${base64encode(local.fleet_proxy_manifest)}' | base64 -d | kubectl --context "$CTX" apply -f -
      kubectl --context "$CTX" -n "${var.namespace}" rollout status deployment/fleet-le-proxy --timeout=180s || \
        echo "WARNING: fleet-le-proxy not ready yet; check: kubectl -n ${var.namespace} get pods -l app=fleet-le-proxy"
    EOT
  }

  # In-place on replace; namespace teardown removes the proxy resources.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving fleet-le-proxy in place on replace; namespace teardown removes it.'"
  }

  depends_on = [terraform_data.fleet_cert, terraform_data.fleet_server_ca, terraform_data.elastic_stack]
}
