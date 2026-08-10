output "healthy_instance_name" {
  description = "Name of the healthy test instance"
  value       = google_sql_database_instance.healthy.name
}

output "exposed_instance_name" {
  description = "Name of the exposed test instance"
  value       = google_sql_database_instance.exposed.name
}

output "test_scenarios" {
  description = "Test scenarios provisioned by this infrastructure"
  value = {
    healthy_instance        = google_sql_database_instance.healthy.name
    publicly_exposed_instance = google_sql_database_instance.exposed.name
  }
}
