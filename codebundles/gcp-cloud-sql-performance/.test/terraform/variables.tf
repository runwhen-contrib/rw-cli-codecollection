variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud SQL instances"
  type        = string
  default     = "us-central1"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}
