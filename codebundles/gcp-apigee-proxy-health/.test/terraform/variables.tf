variable "project_id" {
  description = "GCP project ID where the Apigee org/runtime is hosted"
  type        = string
}

variable "region" {
  description = "GCP region for the Apigee analytics and runtime"
  type        = string
  default     = "us-west1"
}

variable "network_id" {
  description = "ID (URL) of the VPC network for the authorized network of an Apigee org"
  type        = string
  default     = "default"
}

variable "resource_suffix" {
  description = "Short suffix appended to resource names to avoid collisions"
  type        = string
  default     = "test001"
}
