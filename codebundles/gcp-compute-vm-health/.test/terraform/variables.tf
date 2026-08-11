variable "project_id" {
  description = "The GCP project ID where test resources are provisioned."
  type        = string
}

variable "region" {
  description = "The GCP region for the test VPC/subnet (must contain var.zone)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for the test VMs."
  type        = string
  default     = "us-central1-a"
}

variable "resource_suffix" {
  description = "Short unique suffix appended to resource names to avoid collisions."
  type        = string
  default     = "001"
}
