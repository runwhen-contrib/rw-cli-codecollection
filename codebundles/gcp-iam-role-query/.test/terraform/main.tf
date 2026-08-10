terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Test Scenario 1: known_service_account
# A service account with documented IAM bindings that should resolve cleanly.
# -----------------------------------------------------------------------------
resource "google_service_account" "query_target" {
  account_id   = "gcp-iam-query-test-${var.resource_suffix}"
  display_name = "GCP IAM Role Query test service account"
}

resource "google_project_iam_member" "query_target_binding" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.query_target.email}"
}

# A second binding to exercise multiple roles per principal in the report.
resource "google_project_iam_member" "query_target_binding2" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.query_target.email}"
}

# -----------------------------------------------------------------------------
# Test Scenario 2: unknown_resource
# A bucket the query tool will attempt to read; the unknown_resource scenario
# is exercised by passing a name that does not exist.
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "query_bucket" {
  name                        = "gcp-iam-query-${var.resource_suffix}-${var.bucket_suffix}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
