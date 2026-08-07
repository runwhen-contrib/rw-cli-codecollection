# GCP BigQuery Quota Health

Monitors BigQuery quota and capacity health including slot utilization, storage quotas, query per-day limits, and dataset/table count limits. Alerts operators when quotas approach exhaustion so they can request increases or optimize usage before workloads are impacted.

## Overview

- **Slot Utilization**: Queries the BigQuery Reservation API and Cloud Monitoring to check slot utilization against purchased reservation capacity. Raises issues when utilization exceeds a configurable threshold.
- **Storage Quota**: Checks logical and physical storage against quota limits using INFORMATION_SCHEMA and Cloud Monitoring. Raises issues when total storage exceeds a configurable percentage of the project quota.
- **Query Per-Day Limit**: Monitors daily query counts from INFORMATION_SCHEMA against project-level per-day query limits. Raises issues when the project is close to hitting the daily query cap.
- **Dataset and Table Limits**: Counts datasets and tables across the project and checks against GCP limits (10k tables per dataset, 10k datasets per project). Raises issues when approaching limits.
- **Quota Health Summary**: Produces a consolidated quota health summary including slot utilization percentage, storage versus quota, daily query count, and dataset/table counts.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing BigQuery resources.

### Optional Variables

- `SLOT_UTILIZATION_THRESHOLD`: Slot utilization percentage that triggers an alert (default: `80`).
- `STORAGE_QUOTA_THRESHOLD`: Storage usage percentage of quota that triggers an alert (default: `85`).
- `DAILY_QUERY_THRESHOLD`: Daily query count percentage of limit that triggers an alert (default: `80`).
- `DATASET_TABLE_THRESHOLD`: Dataset/table count percentage of max that triggers an alert (default: `80`).

Advanced overrides (optional, passed to the environment):

- `BIGQUERY_ADMIN_PROJECT`: Project where BigQuery reservations are administered (defaults to `GCP_PROJECT_ID`).
- `BIGQUERY_LOCATION`: Reservation location (default: `US`).
- `BIGQUERY_STORAGE_QUOTA_BYTES`: Project storage quota in bytes (default: `10995116277760`, i.e. 10 TB).
- `DAILY_QUERY_LIMIT`: Expected daily query ceiling (default: `100000`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

## Tasks Overview

### Check BigQuery Slot Reservation Utilization
Queries the BigQuery Reservation API and Cloud Monitoring to check slot utilization against purchased reservation capacity. Raises warning/error issues when utilization exceeds the configured `SLOT_UTILIZATION_THRESHOLD`.

### Check BigQuery Storage Quota
Checks logical and physical storage against quota limits using INFORMATION_SCHEMA and Cloud Monitoring. Raises warning/error issues when total storage exceeds the configured `STORAGE_QUOTA_THRESHOLD` of the project quota.

### Check BigQuery Query Per-Day Limit
Monitors daily query counts from INFORMATION_SCHEMA against the project-level per-day query limit. Raises error/critical issues when the project is close to hitting the daily query cap.

### Check BigQuery Dataset and Table Limits
Counts datasets and tables across the project and checks against GCP limits (10k tables per dataset, 10k datasets per project). Raises error issues when approaching limits.

### Generate BigQuery Quota Health Summary
Produces a consolidated quota health summary including slot utilization percentage, storage versus quota, daily query count, and dataset/table counts. Appends the summary to the workspace report.

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/bigquery.admin` or `roles/bigquery.resourceAdmin` for reservation API access
- `roles/monitoring.metrics.list` for Cloud Monitoring metric access
- `roles/bigquery.dataViewer` for INFORMATION_SCHEMA queries

## Platform Tools

- `gcloud` - Google Cloud CLI
- `bq` - BigQuery command-line tool
- `jq` - JSON processor
- `python3` - Python runtime
