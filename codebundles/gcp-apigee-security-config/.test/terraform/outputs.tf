output "apigee_reader_service_account_email" {
  description = "Service account email used to authenticate the CodeBundle"
  value       = google_service_account.apigee_reader.email
}

output "apigee_api_enabled" {
  description = "Whether the Apigee API is enabled in the project"
  value       = google_project_service.apigee.enabled
}
