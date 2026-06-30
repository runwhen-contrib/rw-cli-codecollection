resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "google_project_service" "artifact_registry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container_registry" {
  project            = var.project_id
  service            = "containerregistry.googleapis.com"
  disable_on_destroy = false
}

# Healthy repository with cleanup policies configured
resource "google_artifact_registry_repository" "healthy" {
  depends_on    = [google_project_service.artifact_registry]
  location      = var.region
  repository_id = "${var.codebundle}-healthy-${random_string.suffix.result}"
  description   = "Healthy Docker repo with cleanup policies"
  format        = "DOCKER"
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
}

# Unhealthy repository without cleanup policies (intentional test gap)
resource "google_artifact_registry_repository" "missing_policy" {
  depends_on    = [google_project_service.artifact_registry]
  location      = var.region
  repository_id = "${var.codebundle}-nopolicy-${random_string.suffix.result}"
  description   = "Docker repo missing cleanup policies for governance tests"
  format        = "DOCKER"
}

# Maven repository for discovery-only coverage
resource "google_artifact_registry_repository" "maven" {
  depends_on    = [google_project_service.artifact_registry]
  location      = var.region
  repository_id = "${var.codebundle}-maven-${random_string.suffix.result}"
  description   = "Non-Docker repo for reduced task-set validation"
  format        = "MAVEN"
}

output "healthy_repository" {
  value = google_artifact_registry_repository.healthy.repository_id
}

output "missing_policy_repository" {
  value = google_artifact_registry_repository.missing_policy.repository_id
}

output "maven_repository" {
  value = google_artifact_registry_repository.maven.repository_id
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
