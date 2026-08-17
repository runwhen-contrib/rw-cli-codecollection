variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west1"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}

variable "create_reader_key" {
  description = "Create a JSON key for the reader service account. The private key is stored in Terraform state, so set this to false and mint one with `gcloud iam service-accounts keys create` if the state backend is not somewhere a credential may live."
  type        = bool
  default     = true
}
