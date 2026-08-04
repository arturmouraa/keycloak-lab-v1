# -----------------------------------------------------------------------------
# Gateway module — all Gateway API resources applied via kubectl local-exec
# to avoid the Kubernetes provider's plan-time CRD validation problem.
# -----------------------------------------------------------------------------

locals {
  # NGF 2.5.0 conforms to Gateway API 1.5.x — these MUST move together. If you
  # bump ngf_chart_version, check the matching Gateway API version in NGF's
  # technical-specifications docs and update gateway_api_version to match.
  ngf_chart_version   = "2.5.0"
  ngf_release_name    = "ngf"
  gateway_api_version = "v1.5.1"
  gateway_crds_url    = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${local.gateway_api_version}/standard-install.yaml"

  # NGF's own CRDs (gateway.nginx.org). Helm installs these only on first
  # install and never upgrades them, so we apply them explicitly (server-side)
  # to match the controller version. This is what prevents the stale-schema
  # "invalid number of arguments in server_tokens" breakage on version bumps.
  ngf_crds_url = "https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v${local.ngf_chart_version}/deploy/crds.yaml"

  # The chart creates a default NginxProxy named "<release>-proxy-config" that
  # carries the data-plane service settings (LoadBalancer type + MetalLB IP).
  # The GatewayClass must reference it via parametersRef, otherwise NGF falls
  # back to code defaults that render an empty server_tokens directive.
  nginx_proxy_name = "${local.ngf_release_name}-proxy-config"

  gateway_class_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata   = { name = "nginx" }
    spec = {
      controllerName = "gateway.nginx.org/nginx-gateway-controller"
      parametersRef = {
        group     = "gateway.nginx.org"
        kind      = "NginxProxy"
        name      = local.nginx_proxy_name
        namespace = var.gateway_namespace
      }
    }
  })

  # All listeners share the SAME attribute set so the list has a single element
  # type (Terraform can't concat/conditionally-build lists of differing object
  # shapes). Unused attributes are null; yamlencode omits null-valued keys, so
  # the rendered YAML stays clean.
  tls_terminate = {
    mode = "Terminate"
    certificateRefs = [{
      kind      = "Secret"
      name      = var.tls_secret_name
      namespace = var.keycloak_namespace
    }]
  }

  # Keycloak listeners (default allowedRoutes = Same namespace → null here)
  keycloak_listeners = [
    {
      name          = "https"
      port          = 443
      protocol      = "HTTPS"
      hostname      = var.hostname
      tls           = local.tls_terminate
      allowedRoutes = null
    },
    {
      name          = "http"
      port          = 80
      protocol      = "HTTP"
      hostname      = var.hostname
      tls           = null
      allowedRoutes = null
    }
  ]

  # Optional Kibana listeners. allowedRoutes = All so the HTTPRoute living in the
  # elastic namespace can attach to this Gateway (cross-namespace parentRef).
  # Same cert secret is reused; it carries kibana.local as an additional SAN.
  kibana_listeners_all = [
    {
      name          = "https-kibana"
      port          = 443
      protocol      = "HTTPS"
      hostname      = var.kibana_hostname
      tls           = local.tls_terminate
      allowedRoutes = { namespaces = { from = "All" } }
    },
    {
      name          = "http-kibana"
      port          = 80
      protocol      = "HTTP"
      hostname      = var.kibana_hostname
      tls           = null
      allowedRoutes = { namespaces = { from = "All" } }
    }
  ]

  # A "for ... if" expression yields a consistently-typed list (empty when the
  # condition is false) — avoiding the tuple-length mismatch a ternary produces.
  kibana_listeners = [for l in local.kibana_listeners_all : l if var.enable_kibana_route]

  # Elasticsearch API listeners (same shape/cert; allowedRoutes All for the
  # cross-namespace route from the elastic namespace).
  es_listeners_all = [
    {
      name          = "https-es"
      port          = 443
      protocol      = "HTTPS"
      hostname      = var.es_hostname
      tls           = local.tls_terminate
      allowedRoutes = { namespaces = { from = "All" } }
    },
    {
      name          = "http-es"
      port          = 80
      protocol      = "HTTP"
      hostname      = var.es_hostname
      tls           = null
      allowedRoutes = { namespaces = { from = "All" } }
    }
  ]
  es_listeners = [for l in local.es_listeners_all : l if var.enable_es_route]

  # Fleet Server listeners.
  fleet_listeners_all = [
    {
      name          = "https-fleet"
      port          = 443
      protocol      = "HTTPS"
      hostname      = var.fleet_hostname
      tls           = local.tls_terminate
      allowedRoutes = { namespaces = { from = "All" } }
    },
    {
      name          = "http-fleet"
      port          = 80
      protocol      = "HTTP"
      hostname      = var.fleet_hostname
      tls           = null
      allowedRoutes = { namespaces = { from = "All" } }
    }
  ]
  fleet_listeners = [for l in local.fleet_listeners_all : l if var.enable_fleet_route]

  gateway_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "keycloak-gateway"
      namespace = var.keycloak_namespace
    }
    spec = {
      gatewayClassName = "nginx"
      listeners = concat(
        local.keycloak_listeners,
        local.kibana_listeners,
        local.es_listeners,
        local.fleet_listeners,
      )
    }
  })

  http_redirect_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "keycloak-http-redirect"
      namespace = var.keycloak_namespace
    }
    spec = {
      parentRefs = [{
        name        = "keycloak-gateway"
        namespace   = var.keycloak_namespace
        sectionName = "http"
      }]
      hostnames = [var.hostname]
      rules = [{
        filters = [{
          type = "RequestRedirect"
          requestRedirect = {
            scheme     = "https"
            statusCode = 301
          }
        }]
      }]
    }
  })

  keycloak_route_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "keycloak-route"
      namespace = var.keycloak_namespace
    }
    spec = {
      parentRefs = [{
        name        = "keycloak-gateway"
        namespace   = var.keycloak_namespace
        sectionName = "https"
      }]
      hostnames = [var.hostname]
      rules = [{
        backendRefs = [{
          group = ""
          kind  = "Service"
          name  = "keycloak-service"
          port  = 8080
        }]
      }]
    }
  })
}

# -----------------------------------------------------------------------------
# Step 1 — Install Gateway API CRDs via kubectl
# -----------------------------------------------------------------------------
resource "terraform_data" "gateway_crds" {
  triggers_replace = {
    kube_context        = var.kube_context
    gateway_api_version = local.gateway_api_version
    gateway_crds_url    = local.gateway_crds_url
  }

  # Idempotent: applying a newer standard-install.yaml upgrades the CRDs in
  # place. When gateway_api_version changes this resource is replaced, which
  # re-runs this apply — a safe upgrade, no CR loss.
  provisioner "local-exec" {
    command = "kubectl --context=${self.triggers_replace.kube_context} apply -f ${self.triggers_replace.gateway_crds_url}"
  }

  # Deliberately do NOT delete the Gateway API CRDs on destroy/replace. Deleting
  # them cascade-deletes EVERY Gateway and HTTPRoute in the cluster, so running
  # it on a routine version bump (as a replacement's destroy step) would wipe the
  # live gateway mid-apply. These CRDs are shared cluster infrastructure; if you
  # truly want them gone on teardown, remove them manually:
  #   kubectl delete -f <standard-install.yaml for the installed version>
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Leaving Gateway API CRDs in place (shared cluster infra; delete manually if desired).'"
  }
}

# -----------------------------------------------------------------------------
# Step 2 — Wait for CRDs to be fully established
# -----------------------------------------------------------------------------
resource "terraform_data" "gateway_crds_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    crds_id      = terraform_data.gateway_crds.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Established \
        --timeout=60s \
        crd/gatewayclasses.gateway.networking.k8s.io \
        crd/gateways.gateway.networking.k8s.io \
        crd/httproutes.gateway.networking.k8s.io
    EOT
  }

  depends_on = [terraform_data.gateway_crds]
}

# -----------------------------------------------------------------------------
# Step 2b — Sync NGF's own CRDs (gateway.nginx.org) to the chart version BEFORE
# installing/upgrading the controller. Helm installs these only on first install
# and never upgrades them, so on a version bump the controller would run against
# a stale schema (this is what produced the empty "server_tokens" directive).
# CRDs are cluster-scoped, so applying them first is safe on a fresh cluster and
# matches NGF's documented upgrade order (CRDs first, then the release).
# Server-side apply hands field ownership from Helm to kubectl.
# -----------------------------------------------------------------------------
resource "terraform_data" "ngf_crds" {
  triggers_replace = {
    kube_context = var.kube_context
    ngf_version  = local.ngf_chart_version
    crds_url     = local.ngf_crds_url
  }

  provisioner "local-exec" {
    command = "kubectl --context=${self.triggers_replace.kube_context} apply --server-side --force-conflicts -f ${self.triggers_replace.crds_url}"
  }

  depends_on = [terraform_data.gateway_crds_ready]
}

# -----------------------------------------------------------------------------
# Step 3 — Install NGINX Gateway Fabric via Helm (OCI registry, official method)
# Release name "ngf" matches NGINX docs; deployment will be "ngf-nginx-gateway-fabric"
# -----------------------------------------------------------------------------
resource "helm_release" "nginx_gateway" {
  name             = local.ngf_release_name
  repository       = "oci://ghcr.io/nginx/charts"
  chart            = "nginx-gateway-fabric"
  version          = local.ngf_chart_version
  namespace        = var.gateway_namespace
  create_namespace = true

  # terraform_data.nginx_gateway_ready below already does an explicit
  # `kubectl wait --for=condition=Available` on the controller Deployment, so
  # Helm's own wait would just be a slower, redundant duplicate of the same
  # check — on create it adds nothing, on destroy it blocks on pod
  # termination that nothing downstream needs to wait for.
  wait = false

  set {
    name  = "nginx.service.type"
    value = "LoadBalancer"
  }

  # On bare-metal (MetalLB) pin the gateway's LoadBalancer IP so the hostnames
  # in /etc/hosts are deterministic. Empty on Docker Desktop (no annotation).
  dynamic "set" {
    for_each = var.gateway_load_balancer_ip != "" ? [1] : []
    content {
      name  = "nginx.service.annotations.metallb\\.universe\\.tf/loadBalancerIPs"
      value = var.gateway_load_balancer_ip
    }
  }

  depends_on = [terraform_data.gateway_crds_ready, terraform_data.ngf_crds]
}

# -----------------------------------------------------------------------------
# Step 4 — Wait for NGINX Gateway Fabric deployment to be available
# Deployment name is "<release-name>-nginx-gateway-fabric" = "ngf-nginx-gateway-fabric"
# -----------------------------------------------------------------------------
resource "terraform_data" "nginx_gateway_ready" {
  triggers_replace = {
    kube_context      = var.kube_context
    gateway_namespace = var.gateway_namespace
    helm_revision     = helm_release.nginx_gateway.metadata[0].revision
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Available \
        --timeout=120s \
        -n ${self.triggers_replace.gateway_namespace} \
        deployment/ngf-nginx-gateway-fabric
    EOT
  }

  depends_on = [helm_release.nginx_gateway]
}

# -----------------------------------------------------------------------------
# Step 5 — Apply GatewayClass, Gateway, HTTPRoutes via kubectl
# triggers_replace stores everything needed at destroy time via self.*
#
# Destroy: each delete is guarded by a CRD existence check so that if the
# Gateway API CRDs were already removed earlier in the destroy sequence,
# the command exits cleanly instead of erroring with "resource type not found".
# -----------------------------------------------------------------------------
resource "terraform_data" "gateway_manifests" {
  triggers_replace = {
    kube_context        = var.kube_context
    keycloak_namespace  = var.keycloak_namespace
    gateway_class_yaml  = local.gateway_class_yaml
    gateway_yaml        = local.gateway_yaml
    http_redirect_yaml  = local.http_redirect_yaml
    keycloak_route_yaml = local.keycloak_route_yaml
  }

  # Each manifest is base64-encoded before being embedded in the command and
  # decoded on the way into kubectl, so no character in the rendered YAML
  # (e.g. a stray single quote from a hostname/var) can break out of the
  # shell string and get interpreted as a command.
  provisioner "local-exec" {
    command = <<-EOT
      echo '${base64encode(self.triggers_replace.gateway_class_yaml)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f - && \
      echo '${base64encode(self.triggers_replace.gateway_yaml)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f - && \
      echo '${base64encode(self.triggers_replace.http_redirect_yaml)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f - && \
      echo '${base64encode(self.triggers_replace.keycloak_route_yaml)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} \
        get crd httproutes.gateway.networking.k8s.io > /dev/null 2>&1 && \
        kubectl --context=${self.triggers_replace.kube_context} delete httproute \
          keycloak-route keycloak-http-redirect \
          -n ${self.triggers_replace.keycloak_namespace} --ignore-not-found \
        || true

      kubectl --context=${self.triggers_replace.kube_context} \
        get crd gateways.gateway.networking.k8s.io > /dev/null 2>&1 && \
        kubectl --context=${self.triggers_replace.kube_context} delete gateway \
          keycloak-gateway \
          -n ${self.triggers_replace.keycloak_namespace} --ignore-not-found \
        || true

      kubectl --context=${self.triggers_replace.kube_context} \
        get crd gatewayclasses.gateway.networking.k8s.io > /dev/null 2>&1 && \
        kubectl --context=${self.triggers_replace.kube_context} delete gatewayclass \
          nginx --ignore-not-found \
        || true
    EOT
  }

  depends_on = [terraform_data.nginx_gateway_ready]
}
