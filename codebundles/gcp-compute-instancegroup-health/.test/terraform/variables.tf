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
  description = "Name of the healthy managed instance group"
  type        = string
  default     = "ig-healthy-test001"
}

variable "instance_group_name_degraded" {
  description = "Name of the degraded (empty) unmanaged instance group"
  type        = string
  default     = "ig-degraded-test001"
}
