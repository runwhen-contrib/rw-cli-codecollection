variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for regional resources"
  type        = string
  default     = "us-central1"
}

variable "resource_suffix" {
  description = "Unique suffix for resource names to avoid conflicts"
  type        = string
  default     = "test001"
}

variable "managed_service_wait" {
  description = <<-EOT
    How long to wait after creating the Apis before enabling their Service
    Infrastructure managed services.

    Creating an Api provisions its managed service, but the service is not
    immediately registered for binding. Enabling too early fails with
    "Error 403: Not found or permission denied for service(s)" -- misleading
    wording, since the caller does hold servicemanagement.services.bind and
    serviceusage.services.enable; the service simply is not ready yet.

    Raise this if `terraform apply` still fails on google_project_service.managed.
  EOT
  type        = string
  default     = "150s"
}
