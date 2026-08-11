variable "project_id" {
  description = "GCP project that owns the Apigee organization"
  type        = string
}

variable "apigee_org" {
  description = "Apigee organization name; if empty, defaults to the project ID"
  type        = string
  default     = ""
}

variable "resource_suffix" {
  description = "Unique suffix for fixture names to avoid collisions on the shared org"
  type        = string
  default     = "test001"
}
