output "healthy_instance" {
  value = google_sql_database_instance.healthy.name
}

output "overutilized_instance" {
  value = google_sql_database_instance.overutilized.name
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
