output "healthy_instance_id" {
  description = "ID of the healthy test Spanner instance"
  value       = google_spanner_instance.healthy_instance.name
}

output "healthy_database_id" {
  description = "ID of the healthy test database"
  value       = google_spanner_database.healthy_database.name
}

output "overloaded_instance_id" {
  description = "ID of the overloaded test Spanner instance"
  value       = google_spanner_instance.overloaded_instance.name
}

output "overloaded_database_id" {
  description = "ID of the overloaded scenario's test database"
  value       = google_spanner_database.overloaded_database.name
}
