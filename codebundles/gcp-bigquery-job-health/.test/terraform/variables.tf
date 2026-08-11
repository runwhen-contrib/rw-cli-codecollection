variable "gcp_project_id" {
  description = "The GCP project ID to create test resources in"
  type        = string
}

variable "service_account_key" {
  description = "Path to the GCP service account JSON key file"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}
