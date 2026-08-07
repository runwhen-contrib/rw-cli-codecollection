output "mock_data_bucket" {
  value = google_storage_bucket.apigee_mock_data.name
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
