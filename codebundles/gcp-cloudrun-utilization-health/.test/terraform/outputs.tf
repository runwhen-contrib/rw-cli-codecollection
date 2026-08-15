output "healthy_service_name" {
  value = google_cloud_run_service.healthy.name
}

output "unbounded_service_name" {
  value = google_cloud_run_service.unbounded.name
}

output "mininstances_service_name" {
  value = google_cloud_run_service.mininstances.name
}

output "lowconcurrency_service_name" {
  value = google_cloud_run_service.lowconcurrency.name
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
