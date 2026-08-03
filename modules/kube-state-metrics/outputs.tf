output "namespace" {
  value = var.namespace
}

output "service" {
  description = "In-cluster metrics endpoint"
  value       = "http://kube-state-metrics.${var.namespace}.svc.cluster.local:8080/metrics"
}

output "elastic_integration_host" {
  description = "Value to use for the KSM host in the Elastic kubernetes integration"
  value       = "kube-state-metrics.${var.namespace}.svc.cluster.local:8080"
}
