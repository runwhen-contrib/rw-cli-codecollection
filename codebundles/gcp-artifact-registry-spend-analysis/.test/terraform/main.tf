terraform {
  required_version = ">= 1.5.0"
}

# BigQuery billing export is organization-scoped and cannot be synthesized in CI.
# This placeholder keeps the standard .test/terraform layout for future fixture work.

output "note" {
  value = "Use an existing GCP billing export table for integration testing."
}
