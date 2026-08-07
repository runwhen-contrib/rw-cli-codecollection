output "balanced_environment_name" {
  description = "Name of the balanced (healthy) test Cloud Composer environment"
  value       = google_composer_environment.balanced.name
}

output "balanced_environment_id" {
  description = "Full resource id of the balanced test environment"
  value       = google_composer_environment.balanced.id
}

output "composer_test_service_account" {
  description = "Email of the test service account"
  value       = google_service_account.composer_test.email
}
