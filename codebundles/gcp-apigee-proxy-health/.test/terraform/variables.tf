variable "project_id" {
  type        = string
  description = "GCP project ID that owns the Apigee test org"
}

variable "apigee_service_account" {
  type        = string
  default     = ""
  description = "Service account email to grant Apigee viewer roles for the bundle"
}

variable "resource_suffix" {
  description = "Unique suffix for fixture names, so runs against the shared Apigee organization do not collide. Matches the sibling GCP bundles' convention."
  type        = string
  default     = "test001"
}
