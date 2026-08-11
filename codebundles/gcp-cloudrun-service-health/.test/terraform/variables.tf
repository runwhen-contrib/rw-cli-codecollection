variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud Run services"
  type        = string
  default     = "us-central1"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}

variable "service_account_email" {
  description = "Email of a service account to run the Cloud Run services (least-privilege)."
  type        = string
  default     = ""
}
