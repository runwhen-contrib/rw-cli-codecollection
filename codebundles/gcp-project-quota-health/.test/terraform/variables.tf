variable "project_id" {
  description = "GCP project ID whose quotas are monitored"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "US"
}

variable "credentials_file" {
  description = "Path to the GCP service account JSON key file"
  type        = string
  default     = ""
}
