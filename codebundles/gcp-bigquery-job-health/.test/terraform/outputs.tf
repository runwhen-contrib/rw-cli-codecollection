output "dataset_id" {
  description = "The ID of the test BigQuery dataset"
  value       = google_bigquery_dataset.test_dataset.dataset_id
}

output "table_id" {
  description = "The ID of the test BigQuery table"
  value       = google_bigquery_table.test_table.table_id
}