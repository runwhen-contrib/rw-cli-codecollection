variable "project_id" {
  description = "GCP project ID under audit"
  type        = string
}

variable "org_id" {
  description = "GCP organization ID used to configure project-level org policy constraints"
  type        = string
  default     = ""
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "US"
}
