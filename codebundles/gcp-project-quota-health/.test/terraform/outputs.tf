output "project_id" {
  description = "GCP project ID used for quota health testing"
  value       = data.google_project.quota_health_project.project_id
}

output "project_number" {
  description = "GCP project number used for quota health testing"
  value       = data.google_project.quota_health_project.number
}

output "monitoring_api_enabled" {
  description = "Whether the Cloud Monitoring API is enabled on the project"
  value       = data.google_project_service.monitoring.service
}

output "logging_api_enabled" {
  description = "Whether the Cloud Logging API is enabled on the project"
  value       = data.google_project_service.logging.service
}

output "serviceusage_api_enabled" {
  description = "Whether the Service Usage API is enabled on the project"
  value       = data.google_project_service.serviceusage.service
}
