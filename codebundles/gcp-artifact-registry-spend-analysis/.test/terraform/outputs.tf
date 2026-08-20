output "billing_export_table" {
  description = "BigQuery billing export table the harness analyzes (set via TF_VAR_billing_export_table / tf.secret)"
  value       = var.billing_export_table
}

output "note" {
  description = "Reminder that billing export is organization-scoped and supplied, not provisioned"
  value       = "Use an existing GCP billing export table for integration testing."
}
