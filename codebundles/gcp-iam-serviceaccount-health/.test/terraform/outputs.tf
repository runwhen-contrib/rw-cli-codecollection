output "healthy_sa_email" {
  description = "Email of the healthy test service account"
  value       = google_service_account.healthy_sa.email
}

output "privileged_sa_email" {
  description = "Email of the privileged test service account"
  value       = google_service_account.privileged_sa.email
}

output "excessive_keys_sa_email" {
  description = "Email of the excessive keys test service account"
  value       = google_service_account.excessive_keys_sa.email
}

output "disabled_sa_email" {
  description = "Email of the disabled test service account"
  value       = google_service_account.disabled_sa.email
}
