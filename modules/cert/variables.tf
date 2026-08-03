variable "hostname" {}
variable "namespace" {}

variable "extra_hostnames" {
  description = "Additional DNS SANs to include in the server certificate (e.g. kibana.local)"
  type        = list(string)
  default     = []
}

# --- cert-manager / Let's Encrypt path ---
variable "use_cert_manager" {
  description = "Issue the TLS cert via cert-manager (Let's Encrypt) instead of the built-in self-signed CA. Requires cert-manager + a ClusterIssuer already installed (see ../proxmox-k8s). Hostnames must be public, Cloudflare-managed names."
  type        = bool
  default     = false
}

variable "cluster_issuer" {
  description = "Name of the cert-manager ClusterIssuer to use when use_cert_manager = true (e.g. letsencrypt-staging or letsencrypt-prod)"
  type        = string
  default     = ""
}

variable "kube_context" {
  description = "kubectl context (used by the cert-manager local-exec path)"
  type        = string
  default     = ""
}
