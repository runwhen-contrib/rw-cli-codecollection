output "healthy_dataset_id" {
  description = "ID of the healthy test dataset"
  value       = google_bigquery_dataset.healthy_dataset.dataset_id
}

output "no_expiration_dataset_id" {
  description = "ID of the dataset without expiration"
  value       = google_bigquery_dataset.no_expiration_dataset.dataset_id
}

output "public_dataset_id" {
  description = "ID of the dataset with public access"
  value       = google_bigquery_dataset.public_dataset.dataset_id
}

output "healthy_table_id" {
  description = "ID of the healthy test table"
  value       = google_bigquery_table.healthy_table.table_id
}

output "large_table_id" {
  description = "ID of the large table without expiration"
  value       = google_bigquery_table.large_table_no_expiration.table_id
}