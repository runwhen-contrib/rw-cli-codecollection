# GCP BigQuery Job Health

Monitors BigQuery job execution health by analyzing success/failure rates, error patterns, and performance anomalies. Helps operators identify failed queries, stuck jobs, and systemic issues affecting BigQuery workloads.

## Overview

- **Job Success Rate**: Calculates the job success rate over a configurable lookback window and raises issues if below threshold
- **Error Pattern Analysis**: Categorizes failed jobs by error reason (quotaExceeded, invalidQuery, timeout, accessDenied, etc.)
- **Slow Job Detection**: Identifies jobs exceeding a configurable duration threshold
- **Slot Contention Analysis**: Detects periods where slot demand exceeds reservation capacity

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that contains the BigQuery jobs to monitor

### Optional Variables

- `JOB_LOOKBACK_HOURS`: Number of hours to look back for job analysis (default: `24`)
- `SUCCESS_RATE_THRESHOLD`: Minimum acceptable job success rate percentage (default: `95`)
- `SLOW_JOB_DURATION_MINUTES`: Duration in minutes above which a job is considered slow (default: `30`)
- `SLOT_CONTENTION_THRESHOLD`: Slot utilization percentage indicating contention (default: `80`)

### Secrets

- `gcp_credentials`: GCP service account JSON key used to authenticate with GCP APIs. Format: JSON object containing type, project_id, private_key_id, private_key, client_email, client_id, auth_uri, token_uri

## Prerequisites

### Required GCP Permissions

The service account needs the following roles:
- `roles/bigquery.jobUser` - to run queries against INFORMATION_SCHEMA
- `roles/bigquery.metadataViewer` - to access BigQuery metadata

### Required Tools

- `gcloud` CLI (Google Cloud SDK)
- `bq` command-line tool (included with gcloud)
- `jq` for JSON processing
- `bc` for numeric comparisons
- Bash 4.0 or higher

## Tasks Overview

### Check BigQuery Job Success Rate
Queries `INFORMATION_SCHEMA.JOBS_BY_PROJECT` to calculate the percentage of successful jobs. Raises a severity 3 issue if the success rate falls below the configured threshold. Severity 2 or 3 depending on severity of failure rate.

### Analyze Failed BigQuery Job Error Patterns
Categorizes failed jobs by error reason using `INFORMATION_SCHEMA.JOBS_BY_PROJECT`. Detects frequent error categories like quotaExceeded, invalidQuery, timeout, accessDenied, and provides targeted remediation guidance for each category.

### Identify Slow Running BigQuery Jobs
Detects jobs exceeding the configured duration threshold via `INFORMATION_SCHEMA.JOBS_BY_PROJECT`. Raises issues based on the number of slow jobs: severity 4 for widespread issues (>20 jobs), severity 3 for moderate issues (>5 jobs), severity 2 for isolated cases.

### Check BigQuery Job Slot Contention
Analyzes slot usage from `INFORMATION_SCHEMA.JOBS_TIMELINE` to detect contention periods. Raises severity 3 for significant contention (>10 periods) or severity 2 for minor contention.

## Related Resources

- [BigQuery INFORMATION_SCHEMA Documentation](https://cloud.google.com/bigquery/docs/reference/standard-sql/information-schema)
- [BigQuery Monitoring](https://cloud.google.com/bigquery/docs/monitoring)
- [BigQuery Slots and Reservations](https://cloud.google.com/bigquery/docs/reservations-intro)