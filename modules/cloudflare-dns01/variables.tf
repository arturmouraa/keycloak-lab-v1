terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}

variable "kube_context" {}

variable "cert_manager_namespace" {
  description = "Namespace to install cert-manager into. ClusterIssuer-referenced secrets (the Cloudflare API token, ACME account keys) are looked up here too — cert-manager defaults its 'cluster resource namespace' to its own release namespace."
  default     = "cert-manager"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version (matches the app version, no leading 'v')"
  default     = "1.21.1"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to Zone:DNS:Edit on the zone(s) covering your hostnames. Used for the ACME DNS-01 challenge. Prefer a scoped token over the legacy Global API Key."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.cloudflare_api_token) > 0
    error_message = "cloudflare_api_token must be set — see https://developers.cloudflare.com/fundamentals/api/get-started/create-token/ (Zone:DNS:Edit permission on your zone)."
  }
}

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for expiry notices and ACME account recovery"
  type        = string

  validation {
    condition     = length(var.acme_email) > 0
    error_message = "acme_email must be set."
  }
}
