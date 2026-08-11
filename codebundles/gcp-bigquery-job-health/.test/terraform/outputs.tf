output "dataset_id" {
  description = "The ID of the test BigQuery dataset"
  value       = google_bigquery_dataset.test_dataset.dataset_id
}

output "table_id" {
  description = "The ID of the test BigQuery table"
  value       = google_bigquery_table.test_table.table_id
}

output "test_instructions" {
  description = "How to run the codebundle against the test resources"
  value       = <<-EOT
    After terraform apply, run the codebundle:

      export GCP_PROJECT_ID=${var.gcp_project_id}
      export JOB_LOOKBACK_HOURS=1
      export SUCCESS_RATE_THRESHOLD=95
      bash check_job_success_rate.sh
      bash analyze_failed_jobs.sh
      bash identify_slow_jobs.sh
      bash check_slot_contention.sh

    Expected issues:
      - Success rate 50% → triggers severity 3 (below 95% threshold)
      - Error patterns: invalidQuery (2 occurrences), notFound (2 occurrences) → severity 2 each

    To suppress success_rate issues (e.g. if too much time has passed):
      SUCCESS_RATE_THRESHOLD=50 bash check_job_success_rate.sh
  EOT
}
