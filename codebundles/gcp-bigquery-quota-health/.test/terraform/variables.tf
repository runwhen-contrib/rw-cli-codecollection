variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "US"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}
