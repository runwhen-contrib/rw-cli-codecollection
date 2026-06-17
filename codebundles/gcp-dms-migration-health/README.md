# GCP Database Migration Service (DMS) Health

This CodeBundle monitors Google Cloud Database Migration Service (DMS) migration jobs for failed or stuck states, surfaces recent asynchronous operation failures, and evaluates CDC replication lag using Cloud Monitoring metrics (`migration_job/max_replica_sec_lag` and optionally `migration_job/max_replica_bytes_lag` on resource type `datamigration.googleapis.com/MigrationJob`). It helps confirm migrations are progressing and cutover-ready.

## Overview

- **Migration jobs**: Lists jobs with `gcloud database-migration migration-jobs list` using `--region` set from `GCP_DMS_LOCATION` (see [gcloud reference](https://cloud.google.com/sdk/gcloud/reference/database-migration/)). Flags terminal failures, long-lived transitional states, paused/cancelled jobs, and RUNNING jobs that remain outside CDC beyond a time threshold when continuous replication is expected.
- **Operations**: Lists recent DMS operations and raises issues on operation-level errors and long-running incomplete operations.
- **Replication lag**: For jobs in CDC phase, reads Cloud Monitoring time series and compares lag to `REPLICATION_LAG_SEC_THRESHOLD` and optional byte lag. Google documents that samples can appear in Monitoring up to about **180 seconds** after the observation window.
- **Describe**: Runs `gcloud database-migration migration-jobs describe` for jobs you name explicitly or that prior tasks flagged.
- **Logs**: Optionally correlates Cloud Logging entries for `datamigration.googleapis.com` when unhealthy jobs were flagged.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP project ID that contains the DMS migration jobs.
- `GCP_DMS_LOCATION`: DMS location ID passed to `gcloud database-migration ... --region` (for example `us-central1`).

### Optional Variables

- `DMS_JOB_NAMES`: Comma-separated migration job IDs to scope listing and describe logic, or `All` for every job in the region (default: `All`).
- `REPLICATION_LAG_SEC_THRESHOLD`: Seconds; alert when `max_replica_sec_lag` exceeds this value during CDC (default: `300`).
- `REPLICATION_LAG_BYTES_THRESHOLD`: Bytes; set to `0` to disable byte-lag issues (default: `0`).
- `DMS_STUCK_MINUTES`: Minutes a job may remain in a transitional state (or RUNNING outside CDC) before stuck-style issues (default: `120`).
- `DMS_OPERATION_STUCK_MINUTES`: Minutes an incomplete operation may run before it is treated as stuck (default: `45`).
- `DMS_OPERATION_LIMIT`: Maximum operations returned by `gcloud database-migration operations list` (default: `50`).
- `DMS_LOG_LOOKBACK`: Freshness window for optional error log correlation (for example `1h` or `30m`) (default: `1h`).

### Secrets

- `gcp_credentials`: Service account JSON key. Typical roles include `roles/datamigration.viewer`, `roles/monitoring.viewer`, and `roles/logging.viewer` for list/describe, time series, and log read access.

## Tasks Overview

### List DMS Migration Jobs and Flag Unhealthy States for `${GCP_PROJECT_ID}`

Builds a summary table, writes structured issues for failed/cancelled/paused jobs, stuck transitional states, and delayed progression to CDC, and records flagged job IDs for follow-on tasks.

### List Recent DMS Operations and Flag Failures for `${GCP_PROJECT_ID}`

Surfaces failed operations and operations that stay incomplete beyond `DMS_OPERATION_STUCK_MINUTES`, and appends related job IDs to the shared flag list when identifiers appear in operation metadata.

### Report DMS Replication Lag from Cloud Monitoring for `${GCP_PROJECT_ID}`

Evaluates CDC jobs only for lag alerting. Skips lag evaluation when no jobs are in CDC (for example during full dump), which is expected per Google guidance.

### Summarize DMS Migration Job Details for Flagged Jobs in `${GCP_PROJECT_ID}`

Describes targets from `DMS_JOB_NAMES` when not `All`, otherwise describes jobs accumulated in the flag file from earlier tasks.

### Optional Error Log Correlation for DMS in `${GCP_PROJECT_ID}`

Runs a bounded Cloud Logging query when the flag file is non-empty; otherwise no-ops.

## SLI

`sli.robot` publishes a 0–1 score as the mean of binary dimensions: healthy job list (no FAILED/CANCELLED), operations without errors, and replication lag under threshold when CDC jobs exist.
