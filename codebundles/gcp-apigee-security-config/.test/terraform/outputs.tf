output "apigee_reader_service_account_email" {
  description = "Service account email used to authenticate the CodeBundle"
  value       = google_service_account.apigee_reader.email
}

# There is no apigee_api_enabled output any more. It read
# google_project_service.apigee.enabled, and that resource was removed: this
# bundle is a guest on an org whose APIs the gcp-apigee-environment-health
# sibling owns. Reporting on an API this state does not manage would have
# implied an ownership that no longer exists -- and, while it did exist, made
# `task clean` capable of disabling Apigee under a live org.

output "apigee_reader_key" {
  description = "Base64-encoded JSON key for the reader service account, when create_reader_key is true. Write it out with: terraform output -raw apigee_reader_key | base64 -d > ../gcp.json.secret"
  value       = try(google_service_account_key.apigee_reader[0].private_key, "")
  sensitive   = true
}
