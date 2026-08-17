output "healthy_environment_name" {
  description = "Name of the healthy Cloud Composer test environment"
  value       = google_composer_environment.composer_healthy.name
}

output "outdated_environment_name" {
  description = "Name of the outdated Cloud Composer test environment"
  value       = google_composer_environment.composer_outdated.name
}

output "healthy_environment_region" {
  description = "Region of the healthy Cloud Composer test environment"
  value       = google_composer_environment.composer_healthy.region
}

output "outdated_environment_region" {
  description = "Region of the outdated Cloud Composer test environment"
  value       = google_composer_environment.composer_outdated.region
}
