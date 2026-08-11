output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "healthy_service_name" {
  value = google_cloud_run_service.healthy.name
}

output "broken_service_name" {
  value = "cr-broken-${var.resource_suffix}"
}

output "latest0_service_name" {
  value = "cr-latest0-${var.resource_suffix}"
}
