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
# Test Scenario 1: healthy_service_accounts
# -----------------------------------------------------------------------------
resource "google_service_account" "healthy_sa" {
  account_id   = "healthy-sa-${var.resource_suffix}"
  display_name = "Healthy Service Account"
  description  = "A properly configured service account for testing"
}

resource "google_service_account_key" "healthy_sa_key" {
  service_account_id = google_service_account.healthy_sa.name
  keepers = {
    rotation = timestamp()
  }
}

# Least-privilege binding only
resource "google_service_account_iam_member" "healthy_sa_binding" {
  service_account_id = google_service_account.healthy_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "user:alice@example.com"
}

# -----------------------------------------------------------------------------
# Test Scenario 2: privileged_and_stale_keys
#   - Project-level privileged role (roles/owner) binding
#   - Long-lived key (no rotation keeper changes)
# -----------------------------------------------------------------------------
resource "google_service_account" "privileged_sa" {
  account_id   = "privileged-sa-${var.resource_suffix}"
  display_name = "Privileged Service Account"
  description  = "Service account with a privileged project-level role binding"
}

resource "google_project_iam_member" "privileged_sa_owner" {
  project = var.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.privileged_sa.email}"
}

resource "google_service_account_key" "privileged_sa_stale_key" {
  service_account_id = google_service_account.privileged_sa.name
  public_key_type    = "TYPE_X509_PEM_FILE"
}

# -----------------------------------------------------------------------------
# Test Scenario 3: excessive_keys
#   - Multiple active keys exceeding MAX_KEYS_PER_SA
# -----------------------------------------------------------------------------
resource "google_service_account" "excessive_keys_sa" {
  account_id   = "excessive-keys-sa-${var.resource_suffix}"
  display_name = "Excessive Keys Service Account"
  description  = "Service account holding too many active keys"
}

resource "google_service_account_key" "excessive_key_1" {
  service_account_id = google_service_account.excessive_keys_sa.name
}
resource "google_service_account_key" "excessive_key_2" {
  service_account_id = google_service_account.excessive_keys_sa.name
}
resource "google_service_account_key" "excessive_key_3" {
  service_account_id = google_service_account.excessive_keys_sa.name
}
resource "google_service_account_key" "excessive_key_4" {
  service_account_id = google_service_account.excessive_keys_sa.name
}
resource "google_service_account_key" "excessive_key_5" {
  service_account_id = google_service_account.excessive_keys_sa.name
}
resource "google_service_account_key" "excessive_key_6" {
  service_account_id = google_service_account.excessive_keys_sa.name
}

# -----------------------------------------------------------------------------
# Test Scenario 4: disabled_service_account_in_use
#   - Disabled service account still referenced in project IAM policy
# -----------------------------------------------------------------------------
resource "google_service_account" "disabled_sa" {
  account_id   = "disabled-sa-${var.resource_suffix}"
  display_name = "Disabled Service Account"
  description  = "A disabled service account still referenced in IAM policy"
  disabled     = true
}

resource "google_project_iam_member" "disabled_sa_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.disabled_sa.email}"
}
