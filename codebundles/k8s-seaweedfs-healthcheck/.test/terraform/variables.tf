variable "kubeconfig_path" {
  description = "Path to kubeconfig used for test cluster access"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context for the test cluster"
  type        = string
  default     = "kind-seaweedfs-health-test"
}

variable "namespace" {
  description = "Namespace for SeaweedFS test deployment"
  type        = string
  default     = "test-seaweedfs-health"
}

variable "release_name" {
  description = "Helm release name for SeaweedFS"
  type        = string
  default     = "seaweedfs"
}

variable "chart_version" {
  description = "SeaweedFS Helm chart version"
  type        = string
  default     = "4.0.386"
}
