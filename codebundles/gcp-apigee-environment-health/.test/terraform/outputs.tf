output "healthy_environment" {
  value = google_apigee_environment.healthy.name
}

output "unattached_environment" {
  value = google_apigee_environment.unattached.name
}

output "primary_instance" {
  value = google_apigee_instance.primary.name
}

output "secondary_instance" {
  value = google_apigee_instance.secondary.name
}

output "healthy_envgroup" {
  value = google_apigee_envgroup.healthy.name
}

output "orphan_envgroup" {
  value = google_apigee_envgroup.orphan.name
}
