output "healthy_forwarding_rule" {
  value = google_compute_global_forwarding_rule.http.name
}

output "https_valid_forwarding_rule" {
  value = google_compute_global_forwarding_rule.https_valid.name
}

output "https_expiring_forwarding_rule" {
  value = google_compute_global_forwarding_rule.https_expiring.name
}

output "unhealthy_forwarding_rule" {
  value = google_compute_global_forwarding_rule.unhealthy.name
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
