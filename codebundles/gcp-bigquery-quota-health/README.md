# GCP BigQuery Quota Health

Monitors BigQuery quota and capacity health including slot utilization, storage quotas, query per-day limits, and dataset/table count limits. Alerts operators when quotas approach exhaustion so they can request increases or optimize usage before workloads are impacted.

## Overview

- **Slot Utilization**: Queries the BigQuery Reservation API and Cloud Monitoring to check slot utilization against purchased reservation capacity. Raises issues when utilization exceeds a configurable threshold.
- **Storage Quota**: Checks logical and physical storage against quota limits using INFORMATION_SCHEMA and Cloud Monitoring. Raises issues when total storage exceeds a configurable percentage of the project quota.
- **Query Per-Day Limit**: Monitors daily query counts from INFORMATION_SCHEMA against project-level per-day query limits. Raises issues when the project is close to hitting the daily query cap.
- **Dataset and Table Limits**: Counts datasets and tables across the project and checks against GCP limits (10k tables per dataset, 10k datasets per project). Raises issues when approaching limits.

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

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/bigquery.resourceViewer` — for BIGQUERY_STORAGE_QUOTA_BYTES and INFORMATION_SCHEMA queries (`bigquery.jobs.listAll`)
- `roles/bigquery.resourceAdmin` — for reservation API access (slot capacity queries)
- `roles/monitoring.viewer` — for Cloud Monitoring REST API access (slot utilization metrics)

### Cross-Project Authentication

When the service account/workload identity belongs to a **different project** than
the target `GCP_PROJECT_ID`, gcloud derives the API consumer/quota project from the
credential's project, not `--project`. This causes a `SERVICE_DISABLED` error
against the *caller's* project even when the target project's APIs are enabled.

This bundle sets `CLOUDSDK_BILLING_QUOTA_PROJECT=$GCP_PROJECT_ID` in the suite
environment to pin the quota project to the target project.

- **Requires**: `roles/serviceusage.serviceUsageConsumer` on the target project
  (for cross-project service accounts only).
- **In-project SAs**: No-op — the environment variable has no effect when the
  credential's project matches `GCP_PROJECT_ID`.

## Platform Tools

- `gcloud` - Google Cloud CLI
- `bq` - BigQuery command-line tool
- `jq` - JSON processor
- `python3` - Python runtime
