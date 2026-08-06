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
# Test Scenario 1: well_configured_project
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "healthy_dataset" {
  dataset_id                  = "healthy_dataset_${var.resource_suffix}"
  friendly_name               = "Healthy Dataset"
  description                 = "A properly configured dataset for testing"
  location                    = var.region
  default_table_expiration_ms = 2592000000  # 30 days

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_table" "healthy_table" {
  dataset_id = google_bigquery_dataset.healthy_dataset.dataset_id
  table_id   = "healthy_table_${var.resource_suffix}"

  time_partitioning {
    type = "DAY"
    field = "ts"
  }

  clustering = ["category"]

  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "name", type = "STRING", mode = "NULLABLE" },
    { name = "ts", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "category", type = "STRING", mode = "NULLABLE" },
    { name = "value", type = "FLOAT64", mode = "NULLABLE" },
  ])
}

# -----------------------------------------------------------------------------
# Test Scenario 2: oversized_tables (no expiration, large tables)
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "no_expiration_dataset" {
  dataset_id    = "no_expiration_dataset_${var.resource_suffix}"
  friendly_name = "No Expiration Dataset"
  description   = "Dataset without default expiration for testing"
  location      = var.region

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_table" "large_table_no_expiration" {
  dataset_id = google_bigquery_dataset.no_expiration_dataset.dataset_id
  table_id   = "large_table_${var.resource_suffix}"
  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "payload", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "large_table_no_partition" {
  dataset_id = google_bigquery_dataset.no_expiration_dataset.dataset_id
  table_id   = "no_partition_large_table_${var.resource_suffix}"
  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "data", type = "STRING", mode = "NULLABLE" },
  ])
}

# -----------------------------------------------------------------------------
# Test Scenario 3: security_misconfigurations
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "public_dataset" {
  dataset_id    = "public_dataset_${var.resource_suffix}"
  friendly_name = "Public Dataset"
  description   = "Dataset with public access for testing"
  location      = var.region

  access {
    role          = "roles/bigquery.dataOwner"
    special_group = "projectOwners"
  }

  access {
    role       = "roles/bigquery.dataViewer"
    iam_member = "allAuthenticatedUsers"
  }

  access {
    role       = "roles/bigquery.dataViewer"
    iam_member = "allUsers"
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}