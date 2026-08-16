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

variable "bucket_suffix" {
  description = "Unique suffix for the storage bucket name to avoid global conflicts"
  type        = string
  default     = "001"
}
