# -----------------------------------------------------------------------------
# Keycloak Operator — official installation method
# Docs: https://www.keycloak.org/operator/installation
# All kubernetes_manifest replaced with kubectl local-exec to avoid
# Terraform provider plan-time CRD validation failures.
# -----------------------------------------------------------------------------

locals {
  keycloak_version  = "26.0.0"
  base_url          = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${local.keycloak_version}/kubernetes"
  crds_manifest_url = "${local.base_url}/keycloaks.k8s.keycloak.org-v1.yml"
  realm_crd_url     = "${local.base_url}/keycloakrealmimports.k8s.keycloak.org-v1.yml"
  operator_url      = "${local.base_url}/kubernetes.yml"

  bootstrap_secret_name = "keycloak-bootstrap-admin"

  keycloak_cr_yaml = yamlencode({
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "Keycloak"
    metadata = {
      name      = "keycloak"
      namespace = var.namespace
    }
    spec = {
      instances = 1

      # Plain upstream image — not pre-optimized, so startOptimized must be false
      image          = "quay.io/keycloak/keycloak:${local.keycloak_version}"
      startOptimized = false

      # PostgreSQL database — credentials come from the postgres-secret
      db = {
        vendor   = "postgres"
        host     = var.db_host
        port     = var.db_port
        database = var.db_name
        usernameSecret = {
          name = var.db_secret_name
          key  = "POSTGRES_USER"
        }
        passwordSecret = {
          name = var.db_secret_name
          key  = "POSTGRES_PASSWORD"
        }
      }

      # Initial admin account, sourced from a Secret (username/password keys).
      # NOTE: only applied on first ever start, before the master realm exists.
      # Changing the password later requires resetting it inside Keycloak.
      bootstrapAdmin = {
        user = {
          secret = local.bootstrap_secret_name
        }
      }

      # TLS is terminated at the NGINX Gateway; Keycloak runs plain HTTP internally
      http = {
        httpEnabled = true
      }

      # Full external URL (scheme required in KC 26 so issuer/redirect URLs are https)
      hostname = {
        hostname = "https://${var.hostname}"
        strict   = false
      }

      # Trust X-Forwarded-* headers set by NGINX Gateway Fabric
      proxy = {
        headers = "xforwarded"
      }

      # Disable built-in Ingress — routing handled by NGINX Gateway Fabric
      ingress = {
        enabled = false
      }

      additionalOptions = [
        { name = "log-level", value = "INFO" },
      ]
    }
  })

  # ---------------------------------------------------------------------------
  # KeycloakRealmImport CR — provisions a realm + a sample client.
  # The operator only CREATES realms; it never updates or deletes an existing
  # one, so re-applying is safe and idempotent.
  # ---------------------------------------------------------------------------
  realm_import_yaml = yamlencode({
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "KeycloakRealmImport"
    metadata = {
      name      = "${var.realm_name}-import"
      namespace = var.namespace
    }
    spec = {
      keycloakCRName = "keycloak"
      realm = {
        realm       = var.realm_name
        displayName = var.realm_name
        enabled     = true

        clients = [
          {
            clientId              = var.realm_client_id
            enabled               = true
            publicClient          = true
            standardFlowEnabled   = true
            directAccessGrantsEnabled = true
            redirectUris          = var.realm_client_redirect_uris
            webOrigins            = ["+"] # allow CORS from all registered redirect URIs
          }
        ]
      }
    }
  })
}

# -----------------------------------------------------------------------------
# Step 0 — Bootstrap admin credentials Secret (core resource, no CRD needed)
# Must exist in the same namespace as the Keycloak CR, with username/password keys.
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "bootstrap_admin" {
  metadata {
    name      = local.bootstrap_secret_name
    namespace = var.namespace
  }

  data = {
    username = var.admin_user
    password = var.admin_password
  }
}

# -----------------------------------------------------------------------------
# Step 1 — Install Keycloak Operator CRDs via kubectl
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_crds" {
  triggers_replace = {
    kube_context      = var.kube_context
    keycloak_version  = local.keycloak_version
    crds_manifest_url = local.crds_manifest_url
    realm_crd_url     = local.realm_crd_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} apply -f ${self.triggers_replace.crds_manifest_url} && \
      kubectl --context=${self.triggers_replace.kube_context} apply -f ${self.triggers_replace.realm_crd_url}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} delete -f ${self.triggers_replace.crds_manifest_url} --ignore-not-found && \
      kubectl --context=${self.triggers_replace.kube_context} delete -f ${self.triggers_replace.realm_crd_url} --ignore-not-found
    EOT
  }
}

# -----------------------------------------------------------------------------
# Step 2 — Wait for CRDs to be established
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_crds_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    crds_id      = terraform_data.keycloak_crds.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Established \
        --timeout=60s \
        crd/keycloaks.k8s.keycloak.org \
        crd/keycloakrealmimports.k8s.keycloak.org
    EOT
  }

  depends_on = [terraform_data.keycloak_crds]
}

# -----------------------------------------------------------------------------
# Step 3 — Install Operator (Deployment, RBAC, ServiceAccount) via kubectl
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_operator" {
  triggers_replace = {
    kube_context     = var.kube_context
    namespace        = var.namespace
    keycloak_version = local.keycloak_version
    operator_url     = local.operator_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} \
        -n ${self.triggers_replace.namespace} \
        apply -f ${self.triggers_replace.operator_url}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} \
        -n ${self.triggers_replace.namespace} \
        delete -f ${self.triggers_replace.operator_url} --ignore-not-found
    EOT
  }

  depends_on = [terraform_data.keycloak_crds_ready]
}

# -----------------------------------------------------------------------------
# Step 4 — Wait for Operator deployment to be available
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_operator_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
    operator_id  = terraform_data.keycloak_operator.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Available \
        --timeout=120s \
        -n ${self.triggers_replace.namespace} \
        deployment/keycloak-operator
    EOT
  }

  depends_on = [terraform_data.keycloak_operator]
}

# -----------------------------------------------------------------------------
# Step 5 — Apply Keycloak CR via kubectl
# Admin credentials come from the bootstrap-admin Secret created in Step 0.
# Retrieve them (they match your tfvars) with:
#   kubectl get secret keycloak-bootstrap-admin -n keycloak \
#     -o jsonpath='{.data.username}' | base64 -d
#   kubectl get secret keycloak-bootstrap-admin -n keycloak \
#     -o jsonpath='{.data.password}' | base64 -d
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_cr" {
  triggers_replace = {
    kube_context     = var.kube_context
    namespace        = var.namespace
    keycloak_cr_yaml = local.keycloak_cr_yaml
  }

  provisioner "local-exec" {
    command = "echo '${self.triggers_replace.keycloak_cr_yaml}' | kubectl --context=${self.triggers_replace.kube_context} apply -f -"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --context=${self.triggers_replace.kube_context} delete keycloak keycloak -n ${self.triggers_replace.namespace} --ignore-not-found"
  }

  depends_on = [
    terraform_data.keycloak_operator_ready,
    kubernetes_secret.bootstrap_admin,
  ]
}

# -----------------------------------------------------------------------------
# Step 6 — Wait for the Keycloak instance to report Ready
# The operator sets a "Ready" condition on the Keycloak CR once the server
# is up and the database schema has been provisioned.
# -----------------------------------------------------------------------------
resource "terraform_data" "keycloak_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
    cr_id        = terraform_data.keycloak_cr.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Ready \
        --timeout=300s \
        -n ${self.triggers_replace.namespace} \
        keycloak/keycloak
    EOT
  }

  depends_on = [terraform_data.keycloak_cr]
}

# -----------------------------------------------------------------------------
# Step 7 — Apply the KeycloakRealmImport CR (optional)
# Toggle with var.enable_realm_import. The operator runs a one-off Job to
# import the realm; it only creates new realms and never overwrites existing.
# -----------------------------------------------------------------------------
resource "terraform_data" "realm_import" {
  count = var.enable_realm_import ? 1 : 0

  triggers_replace = {
    kube_context      = var.kube_context
    namespace         = var.namespace
    realm_name        = var.realm_name
    realm_import_yaml = local.realm_import_yaml
  }

  provisioner "local-exec" {
    command = "echo '${self.triggers_replace.realm_import_yaml}' | kubectl --context=${self.triggers_replace.kube_context} apply -f -"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} \
        get crd keycloakrealmimports.k8s.keycloak.org > /dev/null 2>&1 && \
        kubectl --context=${self.triggers_replace.kube_context} delete keycloakrealmimport \
          ${self.triggers_replace.realm_name}-import \
          -n ${self.triggers_replace.namespace} --ignore-not-found \
        || true
    EOT
  }

  depends_on = [terraform_data.keycloak_ready]
}
