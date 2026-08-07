output "apigee_org_id" {
  description = "ID of the created Apigee organization"
  value       = google_apigee_organization.test_org.id
}

output "apigee_org_name" {
  description = "Name of the created Apigee organization"
  value       = google_apigee_organization.test_org.name
}

output "test_environment" {
  description = "Name of the populated test environment"
  value       = google_apigee_environment.test_env.name
}

output "empty_environment" {
  description = "Name of the empty test environment"
  value       = google_apigee_environment.empty_env.name
}
