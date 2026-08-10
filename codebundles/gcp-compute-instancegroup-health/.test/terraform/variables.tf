variable "project_id" {
  description = "GCP project ID where the test resources are created"
  type        = string
}

variable "region" {
  description = "GCP region for the test resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the test resources"
  type        = string
  default     = "us-central1-a"
}

variable "resource_suffix" {
  description = "Suffix appended to resource names to avoid collisions"
  type        = string
  default     = "test001"
}

variable "instance_group_name_healthy" {
  description = "Base name of the healthy managed instance group; resource_suffix is appended"
  type        = string
  default     = "ig-healthy"
}

variable "instance_group_name_degraded" {
  description = "Base name of the degraded (empty) unmanaged instance group; resource_suffix is appended"
  type        = string
  default     = "ig-degraded"
}
