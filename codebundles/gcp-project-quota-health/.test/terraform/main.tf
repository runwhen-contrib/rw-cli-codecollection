terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# The quota-health bundle is a read-only, project-level monitor. No discrete
# resources are created; this data source validates project/API access so the
# bundle's analysis scripts can run and emit well-formed results.
# -----------------------------------------------------------------------------
data "google_project" "quota_health_project" {
  project_id = var.project_id
}

data "google_project_service" "monitoring" {
  project = var.project_id
  service = "monitoring.googleapis.com"
}

data "google_project_service" "logging" {
  project = var.project_id
  service = "logging.googleapis.com"
}

data "google_project_service" "serviceusage" {
  project = var.project_id
  service = "serviceusage.googleapis.com"
}
