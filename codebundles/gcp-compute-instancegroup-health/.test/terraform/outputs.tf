output "healthy_instance_group_name" {
  description = "Name of the healthy managed instance group"
  value       = google_compute_instance_group_manager.ig_healthy.name
}

output "degraded_instance_group_name" {
  description = "Name of the degraded (empty) unmanaged instance group"
  value       = google_compute_instance_group.ig_degraded.name
}

output "project_id" {
  description = "GCP project ID hosting the test resources"
  value       = var.project_id
}
