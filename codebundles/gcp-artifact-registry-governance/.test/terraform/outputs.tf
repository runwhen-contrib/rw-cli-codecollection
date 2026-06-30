output "healthy_repository_name" {
  description = "Healthy Docker repository with cleanup policies"
  value       = google_artifact_registry_repository.healthy.repository_id
}

output "missing_policy_repository_name" {
  description = "Docker repository intentionally missing cleanup policies"
  value       = google_artifact_registry_repository.missing_policy.repository_id
}

output "maven_repository_name" {
  description = "Non-Docker repository for discovery-only scenarios"
  value       = google_artifact_registry_repository.maven.repository_id
}
