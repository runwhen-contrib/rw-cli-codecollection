variable "project_id" {
  description = "GCP project ID in which to create test resources"
  type        = string
}

variable "region" {
  description = "GCP region in which to create test resources"
  type        = string
  default     = "us-central1"
}

variable "resource_suffix" {
  description = "Unique suffix used to name test resources"
  type        = string
  default     = "test"
}

variable "service_account" {
  description = "Service account email used by the Composer environments"
  type        = string
}
