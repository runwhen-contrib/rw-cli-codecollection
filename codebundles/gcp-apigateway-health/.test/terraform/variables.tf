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
  description = <<-EOT
    Unique suffix for resource names, so concurrent runs against a shared
    project cannot collide.

    The static default exists only so `terraform` works standalone. It is NOT
    unique: two people (or CI and a person) using it against the same project
    create identically named Apis, Gateways and Cloud Run services, and one
    `terraform destroy` will delete the other's fixtures mid-run. It also makes
    leftover verification meaningless, since filtering by a shared suffix cannot
    distinguish your leftovers from someone else's live fixtures.

    The Taskfile therefore always passes an explicit per-user value and never
    relies on this default. Set RESOURCE_SUFFIX to override it.
  EOT
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
