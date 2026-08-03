locals {
  # Both paths write to this fixed secret name so the gateway's certificateRefs
  # need no changes regardless of how the cert was issued.
  tls_secret_name = "keycloak-tls"
  self_signed     = var.use_cert_manager ? 0 : 1
  cert_manager    = var.use_cert_manager ? 1 : 0
  dns_names       = concat([var.hostname], var.extra_hostnames)
}

# Namespace is shared by both paths (and other modules depend on it existing).
resource "kubernetes_namespace" "keycloak" {
  metadata { name = var.namespace }
}

# =============================================================================
# PATH A — self-signed CA (default). Unchanged behaviour.
# =============================================================================

# --- Self-signed CA ---
resource "tls_private_key" "ca" {
  count     = local.self_signed
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  count             = local.self_signed
  private_key_pem   = tls_private_key.ca[0].private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "Local Dev CA"
    organization = "Dev"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# --- Server cert signed by CA ---
# SANs cover the primary hostname plus any extra hostnames (e.g. kibana.local),
# so the single "keycloak-tls" secret can back multiple gateway listeners.
resource "tls_private_key" "server" {
  count     = local.self_signed
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  count           = local.self_signed
  private_key_pem = tls_private_key.server[0].private_key_pem

  subject {
    common_name  = var.hostname
    organization = "Dev"
  }

  dns_names = local.dns_names
}

resource "tls_locally_signed_cert" "server" {
  count              = local.self_signed
  cert_request_pem   = tls_cert_request.server[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# --- Kubernetes TLS secret (self-signed path only) ---
resource "kubernetes_secret" "tls" {
  count = local.self_signed

  metadata {
    name      = local.tls_secret_name
    namespace = var.namespace
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_locally_signed_cert.server[0].cert_pem
    "tls.key" = tls_private_key.server[0].private_key_pem
  }

  depends_on = [kubernetes_namespace.keycloak]
}

# --- Write CA cert locally so you can trust it in your browser ---
resource "local_file" "ca_cert" {
  count    = local.self_signed
  filename = "${path.root}/certs/ca.crt"
  content  = tls_self_signed_cert.ca[0].cert_pem
}

# =============================================================================
# PATH B — cert-manager / Let's Encrypt. Applies a Certificate CR via kubectl
# (same local-exec pattern as the gateway module, to sidestep the Kubernetes
# provider's plan-time CRD validation). cert-manager fills the same secret name.
# Requires cert-manager + var.cluster_issuer to already exist on the cluster.
# =============================================================================

locals {
  certificate_yaml = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_secret_name
      namespace = var.namespace
    }
    spec = {
      secretName = local.tls_secret_name
      dnsNames   = local.dns_names
      issuerRef = {
        name  = var.cluster_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "terraform_data" "certificate" {
  count = local.cert_manager

  triggers_replace = {
    kube_context     = var.kube_context
    namespace        = var.namespace
    secret_name      = local.tls_secret_name
    certificate_yaml = local.certificate_yaml
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"

      if [ -z "${var.cluster_issuer}" ]; then echo "ERROR: cluster_issuer is empty"; exit 1; fi

      echo "Applying cert-manager Certificate (${local.tls_secret_name}) via ${var.cluster_issuer}..."
      # Piped through base64 so no character in the rendered YAML (e.g. a
      # stray single quote from a hostname/var) can break out of the shell
      # string and get interpreted as a command.
      printf '%s' '${base64encode(local.certificate_yaml)}' | base64 -d | kubectl --context "$CTX" apply -f -

      echo "Waiting for the certificate to be issued (DNS-01 can take a few minutes)..."
      if ! kubectl --context "$CTX" -n "${var.namespace}" wait \
            --for=condition=Ready certificate/${local.tls_secret_name} --timeout=420s; then
        echo "WARNING: certificate not Ready yet. Check: kubectl -n ${var.namespace} describe certificate ${local.tls_secret_name}"
        echo "         and: kubectl -n ${var.namespace} get challenges,orders"
      fi
    EOT
  }

  # Do NOT delete the Certificate on replace. Changing the issuer (e.g.
  # staging -> prod) changes certificate_yaml, which replaces this resource; a
  # destroy-time `kubectl delete` would then remove the live Certificate before
  # the create step re-applies it, briefly leaving none present. The create
  # provisioner's `kubectl apply` already updates the Certificate in place
  # (cert-manager re-issues and bumps the revision, keeping the Secret), so an
  # issuer switch is now seamless. Real teardown is handled by deleting the
  # namespace (kubernetes_namespace.keycloak), which removes the Certificate too.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "echo 'Leaving cert-manager Certificate in place (namespace teardown removes it; avoids a gap on issuer switches).'"
  }

  depends_on = [kubernetes_namespace.keycloak]
}
