variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for regional resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "us-central1-a"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}

variable "network" {
  description = "VPC network name to attach load balancers to"
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Subnetwork name (required for internal LBs and ILBs backends)"
  type        = string
  default     = ""
}
