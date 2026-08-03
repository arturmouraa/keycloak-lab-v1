output "secret_name" {
  description = "TLS secret backing the gateway listeners (same name in both cert modes)"
  value       = "keycloak-tls"

  # Ensure the secret actually exists before dependents read this: in self-signed
  # mode wait on the Secret; in cert-manager mode wait on the Certificate CR.
  depends_on = [kubernetes_secret.tls, terraform_data.certificate]
}

output "ca_cert_pem" {
  description = "Self-signed CA to trust in your browser. Empty when using cert-manager (Let's Encrypt is publicly trusted)."
  value       = var.use_cert_manager ? "" : tls_self_signed_cert.ca[0].cert_pem
}
