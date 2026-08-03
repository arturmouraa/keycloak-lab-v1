# -----------------------------------------------------------------------------
# kube-state-metrics — official prometheus-community chart (OCI registry).
# Listens to the Kubernetes API and exposes cluster-object metrics on :8080.
# The Elastic Agent Kubernetes integration scrapes these for its state_* data.
# No CRDs, so a plain helm_release is all that's needed (Helm waits for readiness).
# -----------------------------------------------------------------------------
resource "helm_release" "kube_state_metrics" {
  name             = "kube-state-metrics"
  repository       = "oci://ghcr.io/prometheus-community/charts"
  chart            = "kube-state-metrics"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = var.create_namespace

  # Helm waits for the Deployment to become available before completing.
  wait    = true
  timeout = 300

  set {
    name  = "replicas"
    value = var.replicas
  }

  # Modest footprint — fine for a single Docker Desktop node.
  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }
}
