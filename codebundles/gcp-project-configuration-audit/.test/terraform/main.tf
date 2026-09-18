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
# Test Scenario: public_bucket_access_allowed
# Set storage.publicAccessPrevention to 'not enforced' at the project level.
# This should be flagged as an org-policy violation by the audit bundle.
# -----------------------------------------------------------------------------
resource "google_project_organization_policy" "public_access_prevention_not_enforced" {
  project    = var.project_id
  constraint = "storage.publicAccessPrevention"
  count      = var.org_id != "" ? 1 : 0

  list_policy {
    allow {
      all = true
    }
    suggested_value = "not enforced"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario: clean_project
# Ensure admin activity audit logging is enabled on the project. Without an
# auditConfig the verify-audit-log-config task raises a coverage-gap issue, so
# a clean project should have one configured.
# -----------------------------------------------------------------------------
resource "google_project_iam_audit_config" "all_services" {
  project = var.project_id
  service = "allServices"
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
  audit_log_config {
    log_type = "POLICY_DENIED"
  }
}
