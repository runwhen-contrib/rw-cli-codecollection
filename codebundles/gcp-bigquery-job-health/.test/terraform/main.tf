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
  credentials = file(var.service_account_key)
  project     = var.gcp_project_id
  region      = var.region
}

# -----------------------------------------------------------------------------
# Test resources: dataset + table
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "test_dataset" {
  dataset_id  = "bq_job_health_test"
  description = "Test dataset for BigQuery job health monitoring"
  location    = "US"
  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_table" "test_table" {
  dataset_id          = google_bigquery_dataset.test_dataset.dataset_id
  table_id            = "test_data"
  deletion_protection = false

  schema = jsonencode([
    { name = "id", type = "INTEGER", mode = "REQUIRED" },
    { name = "name", type = "STRING", mode = "NULLABLE" },
    { name = "value", type = "FLOAT", mode = "NULLABLE" },
    { name = "timestamp", type = "TIMESTAMP", mode = "NULLABLE" },
  ])

  depends_on = [google_bigquery_dataset.test_dataset]
}

# -----------------------------------------------------------------------------
# Data loader: submits test jobs that trigger health-check issues
#
# Scenarios exercised:
#   - 4 successful queries  → baseline
#   - 2 invalidQuery errors → syntax + bad column reference
#   - 2 notFound errors     → missing table + missing dataset
#
# Result: ~50% success rate (below default 95% threshold)
#         Error patterns: invalidQuery and notFound categories
# -----------------------------------------------------------------------------
resource "null_resource" "load_test_jobs" {
  depends_on = [
    google_bigquery_table.test_table,
  ]

  provisioner "local-exec" {
    command     = "bash ${path.module}/load_test_data.sh ${var.gcp_project_id} ${google_bigquery_dataset.test_dataset.dataset_id} ${var.service_account_key}"
    interpreter = ["bash", "-c"]
  }

  triggers = {
    always_run = timestamp()
  }
}
