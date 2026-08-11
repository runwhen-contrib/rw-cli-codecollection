# Test Infrastructure for gcp-bigquery-job-health

This directory contains test infrastructure for the GCP BigQuery Job Health CodeBundle.

## Test Scenarios

### healthy_project
A GCP project with no failed jobs, fast execution, and sufficient slot capacity.
- Expected issues: 0

### failed_jobs_detected
A GCP project with failed jobs due to quota exceedance and invalid queries.
- Expected issues: 3
- Expected severities: [2, 2, 3]

### slot_contention
A GCP project with high slot utilization and slow queued jobs.
- Expected issues: 2
- Expected severities: [2, 3]

## Running Tests

```bash
# Build infrastructure
task build-infra

# Run full test suite
task default

# Clean up
task clean
```

## Terraform

The Terraform configuration creates:
- A GCP project with BigQuery datasets and tables
- Service account with appropriate roles
- Test queries to simulate job patterns

Set the following variables in `terraform.tfvars`:
- `gcp_project_id`: Target project ID
- `service_account_key`: Path to service account JSON key