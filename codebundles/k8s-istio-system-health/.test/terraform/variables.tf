variable "vpc_cidr" {
  description = "The cidr for aws vpc"
  type        = string
  default     = "10.0.0.0/16"
}

variable "istio_version" {
  description = "Istio version"
  type        = string
  default     = "1.20.2"
}

variable "cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
  default     = "istio-cluster"
}