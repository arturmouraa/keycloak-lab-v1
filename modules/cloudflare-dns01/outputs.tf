output "cert_manager_namespace" {
  value = var.cert_manager_namespace
}

output "staging_issuer_name" {
  value = "letsencrypt-staging"
}

output "prod_issuer_name" {
  value = "letsencrypt-prod"
}
