output "healthy_dataset_id" {
  description = "ID of the healthy test dataset"
  value       = google_bigquery_dataset.healthy_dataset.dataset_id
}

output "healthy_table_id" {
  description = "ID of the healthy test table"
  value       = google_bigquery_table.healthy_table.table_id
}

output "stressed_dataset_1_id" {
  description = "ID of the first stressed test dataset"
  value       = google_bigquery_dataset.stressed_dataset_1.dataset_id
}

output "stressed_dataset_2_id" {
  description = "ID of the second stressed test dataset"
  value       = google_bigquery_dataset.stressed_dataset_2.dataset_id
}

output "stressed_table_1_id" {
  description = "ID of the first stressed test table"
  value       = google_bigquery_table.stressed_table_1.table_id
}

output "stressed_table_2_id" {
  description = "ID of the second stressed test table"
  value       = google_bigquery_table.stressed_table_2.table_id
}
