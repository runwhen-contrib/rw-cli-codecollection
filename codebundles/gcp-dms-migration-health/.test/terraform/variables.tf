variable "project_id" {
  description = "GCP project ID that will own the DMS test resources."
  type        = string
}

variable "region" {
  description = "Region for the Cloud SQL instances."
  type        = string
  default     = "us-central1"
}

variable "dms_location" {
  description = "DMS regional location (must match GCP_DMS_LOCATION passed to the robots)."
  type        = string
  default     = "us-central1"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts."
  type        = string
  default     = "cbtest"
}

variable "mysql_version" {
  description = "Cloud SQL MySQL version for source and destination."
  type        = string
  default     = "MYSQL_8_0"
}

variable "source_tier" {
  description = "Machine tier for the source Cloud SQL instance. db-f1-micro is cheaper but slower; db-g1-small is the safer default for DMS."
  type        = string
  default     = "db-g1-small"
}

variable "destination_tier" {
  description = "Machine tier for the DMS-created destination Cloud SQL instance."
  type        = string
  default     = "db-g1-small"
}

variable "disk_size_gb" {
  description = "Data disk size for both instances."
  type        = string
  default     = "10"
}

variable "db_password" {
  description = "Password for the migration user and destination root user."
  type        = string
  default     = "RunWhenDmsTest!234"
  sensitive   = true
}

variable "migration_desired_state" {
  description = <<-EOT
    Desired state of the migration job. Leave null so Terraform only CREATES the
    job (NOT_STARTED) - the job is then started out of band, which keeps a
    connectivity problem a fast CLI error instead of a stuck `terraform apply`.
    Set to "RUNNING" to have Terraform start it and wait for CDC.
  EOT
  type        = string
  default     = null
}
