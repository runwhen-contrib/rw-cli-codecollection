variable "project_id" {
  type        = string
  description = "GCP project ID that owns the Apigee test org"
}

variable "apigee_service_account" {
  type        = string
  default     = ""
  description = "Service account email to grant Apigee viewer roles for the bundle"
}
