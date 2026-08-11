variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "private_network" {
  description = "Self link or name of the VPC network used for private IP Cloud SQL instances"
  type        = string
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}

variable "db_password" {
  description = "Password for the Cloud SQL test user"
  type        = string
  sensitive   = true
  default     = "ChangeMe123!"
}
