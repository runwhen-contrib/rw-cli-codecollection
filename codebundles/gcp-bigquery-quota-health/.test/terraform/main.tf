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
# Test Scenario 1: adequate_capacity (healthy, no issues expected)
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "healthy_dataset" {
  dataset_id                  = "healthy_dataset_${var.resource_suffix}"
  friendly_name               = "Healthy Dataset"
  description                 = "A small, well-contained dataset for testing quota health"
  location                    = var.region
  default_table_expiration_ms = 2592000000

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_table" "healthy_table" {
  dataset_id          = google_bigquery_dataset.healthy_dataset.dataset_id
  table_id            = "healthy_table_${var.resource_suffix}"
  deletion_protection = false

  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "name", type = "STRING", mode = "NULLABLE" },
  ])
}

# -----------------------------------------------------------------------------
# Test Scenario 2: capacity_pressure (many datasets/tables, approaching limits)
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "stressed_dataset_1" {
  dataset_id    = "stressed_dataset_1_${var.resource_suffix}"
  friendly_name = "Stressed Dataset 1"
  description   = "Dataset used to simulate capacity pressure"
  location      = var.region

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_dataset" "stressed_dataset_2" {
  dataset_id    = "stressed_dataset_2_${var.resource_suffix}"
  friendly_name = "Stressed Dataset 2"
  description   = "Dataset used to simulate capacity pressure"
  location      = var.region

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_bigquery_table" "stressed_table_1" {
  dataset_id          = google_bigquery_dataset.stressed_dataset_1.dataset_id
  table_id            = "stressed_table_${var.resource_suffix}"
  deletion_protection = false
  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "payload", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "stressed_table_2" {
  dataset_id          = google_bigquery_dataset.stressed_dataset_2.dataset_id
  table_id            = "stressed_table_${var.resource_suffix}"
  deletion_protection = false
  schema = jsonencode([
    { name = "id", type = "INT64", mode = "REQUIRED" },
    { name = "payload", type = "STRING", mode = "NULLABLE" },
  ])
}
