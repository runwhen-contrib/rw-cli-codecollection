output "protected_instance_id" {
  description = "ID of the protected test Spanner instance"
  value       = google_spanner_instance.protected_instance.name
}

output "protected_database_id" {
  description = "ID of the protected test database"
  value       = google_spanner_database.protected_database.name
}

output "unprotected_instance_id" {
  description = "ID of the unprotected test Spanner instance"
  value       = google_spanner_instance.unprotected_instance.name
}

output "unprotected_database_id" {
  description = "ID of the unprotected scenario's test database"
  value       = google_spanner_database.unprotected_database.name
}
