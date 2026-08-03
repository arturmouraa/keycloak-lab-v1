terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
  }
}

variable "namespace" {
  description = "Namespace to install kube-state-metrics into"
  default     = "kube-system"
}

variable "create_namespace" {
  description = "Create the namespace (leave false for pre-existing ones like kube-system)"
  default     = false
}

variable "chart_version" {
  description = "kube-state-metrics Helm chart version (prometheus-community)"
  default     = "5.27.1"
}

variable "replicas" {
  description = "Number of kube-state-metrics replicas"
  default     = 1
}
