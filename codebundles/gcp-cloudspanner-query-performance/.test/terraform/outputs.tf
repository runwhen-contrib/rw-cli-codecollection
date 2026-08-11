output "healthy_workload_instance_id" {
  description = "ID of the healthy_workload test Spanner instance"
  value       = google_spanner_instance.healthy_workload.name
}

output "healthy_workload_database_id" {
  description = "ID of the healthy_workload test database"
  value       = google_spanner_database.healthy_workload.name
}

output "contended_workload_instance_id" {
  description = "ID of the contended_workload test Spanner instance"
  value       = google_spanner_instance.contended_workload.name
}

output "contended_workload_database_id" {
  description = "ID of the contended_workload test database"
  value       = google_spanner_database.contended_workload.name
}
