provider "google" {
  credentials = file(var.service_account_key)
  project     = var.gcp_project_id
  region      = "us-central1"
}

resource "google_bigquery_dataset" "test_dataset" {
  dataset_id  = "bq_job_health_test"
  description = "Test dataset for BigQuery job health monitoring"
  location    = "US"
}

resource "google_bigquery_table" "test_table" {
  dataset_id = google_bigquery_dataset.test_dataset.dataset_id
  table_id   = "test_data"

  schema = jsonencode([
    { name = "id", type = "INTEGER", mode = "REQUIRED" },
    { name = "name", type = "STRING", mode = "NULLABLE" },
    { name = "value", type = "FLOAT", mode = "NULLABLE" },
    { name = "timestamp", type = "TIMESTAMP", mode = "NULLABLE" },
  ])

  depends_on = [google_bigquery_dataset.test_dataset]
}