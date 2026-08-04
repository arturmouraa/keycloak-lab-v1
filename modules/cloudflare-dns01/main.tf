# -----------------------------------------------------------------------------
# cert-manager + Let's Encrypt via Cloudflare DNS-01 — official install method.
# Installs cert-manager itself (Helm, OCI registry) so this stack is
# self-contained rather than assuming an externally-provisioned cert-manager
# (that's what modules/cert's use_cert_manager path was originally written
# for — a sibling cluster-bootstrap project providing the ClusterIssuer).
#
# Creates BOTH letsencrypt-staging and letsencrypt-prod ClusterIssuers so
# callers can switch via var.cluster_issuer without re-running this module.
#
# Same pattern as the rest of the repo: cert-manager's own CRDs (ClusterIssuer,
# Certificate) can't be targeted by the Kubernetes provider at plan time, so
# the ClusterIssuers are applied via kubectl inside terraform_data +
# local-exec, base64-round-tripped so nothing in the rendered YAML can break
# out of the shell string.
# -----------------------------------------------------------------------------

locals {
  issuers = {
    "letsencrypt-staging" = "https://acme-staging-v02.api.letsencrypt.org/directory"
    "letsencrypt-prod"    = "https://acme-v02.api.letsencrypt.org/directory"
  }

  cluster_issuer_yaml = {
    for name, server in local.issuers : name => yamlencode({
      apiVersion = "cert-manager.io/v1"
      kind       = "ClusterIssuer"
      metadata   = { name = name }
      spec = {
        acme = {
          server = server
          email  = var.acme_email
          privateKeySecretRef = {
            name = "${name}-account-key"
          }
          solvers = [
            {
              dns01 = {
                cloudflare = {
                  apiTokenSecretRef = {
                    name = kubernetes_secret.cloudflare_api_token.metadata[0].name
                    key  = "api-token"
                  }
                }
              }
            }
          ]
        }
      }
    })
  }

  cluster_issuers_manifest = join("\n---\n", values(local.cluster_issuer_yaml))
}

# -----------------------------------------------------------------------------
# Step 1 — Install cert-manager via Helm (CRDs included: crds.enabled=true)
# -----------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "oci://quay.io/jetstack/charts/cert-manager"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = var.cert_manager_namespace
  create_namespace = true

  # terraform_data.cert_manager_ready below already does an explicit
  # `kubectl wait --for=condition=Available` on cert-manager's Deployments, so
  # Helm's own wait would just be a slower, redundant duplicate of the same
  # check — on create it adds nothing, on destroy it blocks on pod
  # termination that nothing downstream needs to wait for.
  wait = false

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# -----------------------------------------------------------------------------
# Step 2 — Wait for the webhook to be Available. cert-manager validates
# ClusterIssuer/Certificate objects through its own admission webhook, so
# applying one before the webhook Deployment is up fails with a connection
# error rather than a clean validation error.
# -----------------------------------------------------------------------------
resource "terraform_data" "cert_manager_ready" {
  triggers_replace = {
    kube_context  = var.kube_context
    namespace     = var.cert_manager_namespace
    helm_revision = helm_release.cert_manager.metadata[0].revision
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Available \
        --timeout=180s \
        -n ${self.triggers_replace.namespace} \
        deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector
    EOT
  }

  depends_on = [helm_release.cert_manager]
}

# -----------------------------------------------------------------------------
# Step 3 — Wait for the ClusterIssuer CRD to be established
# -----------------------------------------------------------------------------
resource "terraform_data" "cert_manager_crds_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    ready_id     = terraform_data.cert_manager_ready.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} wait \
        --for=condition=Established \
        --timeout=60s \
        crd/clusterissuers.cert-manager.io \
        crd/certificates.cert-manager.io
    EOT
  }

  depends_on = [terraform_data.cert_manager_ready]
}

# -----------------------------------------------------------------------------
# Step 4 — Cloudflare API token Secret, in cert-manager's own namespace (its
# default "cluster resource namespace" for ClusterIssuer-referenced secrets).
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = var.cert_manager_namespace
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  depends_on = [helm_release.cert_manager]
}

# -----------------------------------------------------------------------------
# Step 5 — Apply both ClusterIssuers
# -----------------------------------------------------------------------------
resource "terraform_data" "cluster_issuers" {
  triggers_replace = {
    kube_context     = var.kube_context
    namespace        = var.cert_manager_namespace
    issuers_manifest = local.cluster_issuers_manifest
  }

  provisioner "local-exec" {
    command = "echo '${base64encode(self.triggers_replace.issuers_manifest)}' | base64 -d | kubectl --context=${self.triggers_replace.kube_context} apply -f -"
  }

  # cert-manager is treated as shared cluster infra (like the Gateway API CRDs
  # elsewhere in this repo) rather than something owned exclusively by this
  # stack, so destroy leaves it in place instead of uninstalling it — avoids
  # taking out cert-manager (and any unrelated Certificates depending on it)
  # from under the rest of the cluster on a routine `terraform destroy`.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo 'Leaving cert-manager, its ClusterIssuers, and the cloudflare-api-token secret in place.'
      echo 'To remove them by hand:'
      echo '  kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod --ignore-not-found'
      echo '  helm uninstall cert-manager -n ${self.triggers_replace.namespace}'
      echo '  kubectl delete namespace ${self.triggers_replace.namespace} --ignore-not-found'
    EOT
  }

  depends_on = [
    terraform_data.cert_manager_crds_ready,
    kubernetes_secret.cloudflare_api_token,
  ]
}
