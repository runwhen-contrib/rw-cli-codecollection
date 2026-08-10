output "service_account_email" {
  description = "Email of the test service account used for known_service_account scenario"
  value       = google_service_account.query_target.email
}

output "service_account_id" {
  description = "ID of the test service account"
  value       = google_service_account.query_target.id
}

output "query_bucket_name" {
  description = "Name of the test storage bucket used for resource queries"
  value       = google_storage_bucket.query_bucket.name
}
