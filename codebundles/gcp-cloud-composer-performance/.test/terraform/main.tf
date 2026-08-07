# -----------------------------------------------------------------------------
# Test infrastructure for gcp-cloud-composer-performance
#
# Provisions:
#   - one balanced (healthy) Cloud Composer environment
#   - labels appropriate for identification and cleanup
#
# Creating dedicated "unhealthy" environments is impractical/expensive for
# Composer; the same metrics are driven by workload rather than static config.
# This bundle's detections (saturation, backlog, over-provisioning, deltas) are
# all evaluated against Cloud Monitoring, so the primary test resource is a set
# of real Composer environments to run discovery and metric queries against.
# -----------------------------------------------------------------------------

# Service account used by the Composer environment (and, in a full test, by the
# CodeBundle to query Cloud Monitoring).
resource "google_service_account" "composer_test" {
  account_id   = "composer-test-${var.resource_suffix}"
  display_name = "Cloud Composer Performance Test SA"
}

resource "google_project_iam_member" "composer_worker" {
  project = var.project_id
  role    = "roles/composer.worker"
  member  = "serviceAccount:${google_service_account.composer_test.email}"
}

resource "google_project_iam_member" "monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.composer_test.email}"
}

# -----------------------------------------------------------------------------
# Test Scenario 1: balanced_environment
# A standard Composer environment that should report no performance issues.
# -----------------------------------------------------------------------------
resource "google_composer_environment" "balanced" {
  name    = "balanced-composer-${var.resource_suffix}"
  project = var.project_id
  region  = var.region

  config {
    node_count = 3

    software_config {
      airflow_config_overrides = {
        core-load_example = "True"
      }
    }

    node_config {
      service_account = google_service_account.composer_test.email
    }

    workloads_config {
      scheduler {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1.0
        count      = 1
      }
      web_server {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1.0
      }
      worker {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1.0
        min_count  = 2
        max_count  = 6
      }
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
