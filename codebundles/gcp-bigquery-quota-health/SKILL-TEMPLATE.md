---
name: gcp-bigquery-quota-health
kind: skill-template
description: Monitor BigQuery quota and capacity health including slot utilization, storage quotas, query per-day limits, and dataset/table count limits. Use when triaging or monitoring GCP, BigQuery workloads with skill template `gcp-bigquery-quota-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, BigQuery]
resource_types: [gcp_resource]
access: read-only
---

# GCP BigQuery Quota Health

## Summary

Monitors BigQuery quota and capacity health including slot utilization, storage quotas, query per-day limits, and dataset/table count limits. Alerts operators when quotas approach exhaustion so they can request increases or optimize usage before workloads are impacted.

See [README.md](README.md) for additional context.

## Tools

### Check BigQuery Slot Reservation Utilization for `${GCP_PROJECT_ID}`

Queries the BigQuery Reservation API and Cloud Monitoring to check slot utilization against purchased reservation capacity. Raises warning/error issues when utilization exceeds the configured `SLOT_UTILIZATION_THRESHOLD`.

- **Robot task name**: <code>Check BigQuery Slot Reservation Utilization for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_slot_utilization.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `slots`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `SLOT_UTILIZATION_THRESHOLD`, `BIGQUERY_ADMIN_PROJECT`, `BIGQUERY_LOCATION`
- **Writes**: `slot_utilization_issues.json`
- **Issues raised**: severity 3 (>=95%) / severity 2 (>=threshold) when slot utilization exceeds purchased capacity

### Check BigQuery Storage Quota for `${GCP_PROJECT_ID}`

Checks logical and physical storage against quota limits using INFORMATION_SCHEMA and Cloud Monitoring. Raises issues when total storage exceeds a configurable percentage of the project quota.

- **Robot task name**: <code>Check BigQuery Storage Quota for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_storage_quota.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `storage`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `STORAGE_QUOTA_THRESHOLD`, `BIGQUERY_STORAGE_QUOTA_BYTES`
- **Writes**: `storage_quota_issues.json`
- **Issues raised**: severity 3 (>=95%) / severity 2 (>=threshold) when storage exceeds quota threshold

### Check BigQuery Query Per-Day Limit for `${GCP_PROJECT_ID}`

Monitors daily query counts from INFORMATION_SCHEMA against project-level per-day query limits. Raises error/critical issues when the project is close to hitting the daily query cap.

- **Robot task name**: <code>Check BigQuery Query Per-Day Limit for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_query_daily_limit.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `queries`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `DAILY_QUERY_THRESHOLD`, `DAILY_QUERY_LIMIT`
- **Writes**: `query_daily_limit_issues.json`
- **Issues raised**: severity 4 (>=98%) / severity 3 (>=threshold) when daily queries approach limit

### Check BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`

Counts datasets and tables across the project and checks against GCP limits (10k tables per dataset, 10k datasets per project). Raises issues when approaching limits.

- **Robot task name**: <code>Check BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_dataset_table_limits.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `dataset`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `DATASET_TABLE_THRESHOLD`
- **Writes**: `dataset_table_limit_issues.json`
- **Issues raised**: severity 3 when dataset or table counts exceed threshold

## Monitor

This SLI scores BigQuery quota health by evaluating slot utilization, storage quota, daily query count, and dataset/table limits. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score BigQuery Slot Utilization for `${GCP_PROJECT_ID}`

Scores slot utilization against the configured threshold. Returns 1 if acceptable, 0 otherwise.

- **Robot task name**: <code>Score BigQuery Slot Utilization for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `slot_utilization`
- **Underlying script**: `check_slot_utilization.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `slots`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `SLOT_UTILIZATION_THRESHOLD`
- **Pass condition**: slot utilization below threshold

#### Score BigQuery Storage Quota for `${GCP_PROJECT_ID}`

Scores storage usage against the project quota. Returns 1 if below threshold, 0 otherwise.

- **Robot task name**: <code>Score BigQuery Storage Quota for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `storage_quota`
- **Underlying script**: `check_storage_quota.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `storage`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `STORAGE_QUOTA_THRESHOLD`
- **Pass condition**: storage usage below threshold

#### Score BigQuery Daily Query Limit for `${GCP_PROJECT_ID}`

Scores the daily query count against the limit. Returns 1 if within threshold, 0 otherwise.

- **Robot task name**: <code>Score BigQuery Daily Query Limit for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `daily_query_limit`
- **Underlying script**: `check_query_daily_limit.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `queries`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `DAILY_QUERY_THRESHOLD`
- **Pass condition**: daily query count within threshold

#### Score BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`

Scores dataset and table counts against GCP limits. Returns 1 if within threshold, 0 otherwise.

- **Robot task name**: <code>Score BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `dataset_table_limits`
- **Underlying script**: `check_dataset_table_limits.sh`
- **Tags**: `gcp`, `bigquery`, `quota`, `dataset`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `DATASET_TABLE_THRESHOLD`
- **Pass condition**: dataset/table counts within threshold

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing BigQuery resources. | — | yes |
| `SLOT_UTILIZATION_THRESHOLD` | string | Slot utilization percentage that triggers an alert. | `80` | no |
| `STORAGE_QUOTA_THRESHOLD` | string | Storage usage percentage of quota that triggers an alert. | `85` | no |
| `DAILY_QUERY_THRESHOLD` | string | Daily query count percentage of limit that triggers an alert. | `80` | no |
| `DATASET_TABLE_THRESHOLD` | string | Dataset/table count percentage of max that triggers an alert. | `80` | no |
| `BIGQUERY_ADMIN_PROJECT` | string | Project where BigQuery reservations are administered. | `GCP_PROJECT_ID` | no |
| `BIGQUERY_LOCATION` | string | Reservation location. | `US` | no |
| `BIGQUERY_STORAGE_QUOTA_BYTES` | string | Project storage quota in bytes. | `10995116277760` | no |
| `DAILY_QUERY_LIMIT` | string | Expected daily query ceiling. | `100000` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics: `slot_utilization`, `storage_quota`, `daily_query_limit`, `dataset_table_limits`
- `slot_utilization_issues.json`
- `storage_quota_issues.json`
- `query_daily_limit_issues.json`
- `dataset_table_limit_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-bigquery-quota-health/runbook.robot`
- **Monitor**: `codebundles/gcp-bigquery-quota-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-bigquery-quota-health
export GCP_PROJECT_ID=...
export SLOT_UTILIZATION_THRESHOLD=80
export STORAGE_QUOTA_THRESHOLD=85
export DAILY_QUERY_THRESHOLD=80
export DATASET_TABLE_THRESHOLD=80
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-bigquery-quota-health
export GCP_PROJECT_ID=...
export SLOT_UTILIZATION_THRESHOLD=80
export STORAGE_QUOTA_THRESHOLD=85
export DAILY_QUERY_THRESHOLD=80
export DATASET_TABLE_THRESHOLD=80
bash check_slot_utilization.sh
bash check_storage_quota.sh
bash check_query_daily_limit.sh
bash check_dataset_table_limits.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across four health dimensions
- `check_slot_utilization.sh` — queries BigQuery Reservation API and Cloud Monitoring for slot utilization
- `check_storage_quota.sh` — aggregates storage across datasets via INFORMATION_SCHEMA.TABLE_STORAGE
- `check_query_daily_limit.sh` — counts daily queries from INFORMATION_SCHEMA.JOBS_BY_PROJECT
- `check_dataset_table_limits.sh` — counts datasets and tables against GCP quotas