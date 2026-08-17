# -----------------------------------------------------------------------------
# Test infrastructure for gcp-cloud-composer-performance
#
# Provisions:
#   - one balanced (healthy) Cloud Composer 3 environment (ENVIRONMENT_SIZE_SMALL)
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
  project      = var.project_id
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
# Test Scenario: balanced_environment (Cloud Composer 3, small)
# A minimal Composer 3 environment that should report no performance issues.
# Composer 3 runs on GKE Autopilot — no node_count, no machine types.
# Cost: ~$0.30-0.50/hr (vs $0.80-1.50/hr for Composer 2).
# Provision time: ~10-20 min (vs 25-40 min for Composer 2).
# -----------------------------------------------------------------------------
resource "google_composer_environment" "balanced" {
  name    = "balanced-composer-${var.resource_suffix}"
  project = var.project_id
  region  = var.region

  config {
    environment_size = "ENVIRONMENT_SIZE_SMALL"

    software_config {
      image_version = "composer-3-airflow-2"
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
        memory_gb  = 2
        storage_gb = 1
        count      = 1
      }
      web_server {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
      }
      worker {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
        min_count  = 1
        max_count  = 3
      }
      dag_processor {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
        count      = 1
      }
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
