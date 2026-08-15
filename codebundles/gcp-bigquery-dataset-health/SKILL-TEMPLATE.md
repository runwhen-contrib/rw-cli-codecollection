---
name: gcp-bigquery-dataset-health
kind: skill-template
description: Monitors BigQuery dataset and table health including size trends, access control configuration, expiration policies, and audit logging. Use when triaging or monitoring GCP, BigQuery workloads with skill template `gcp-bigquery-dataset-health`.
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

# GCP BigQuery Dataset Health

## Summary

This codebundle monitors BigQuery datasets and tables for health issues including table size trends, dataset access configuration, table expiration policies, audit logging, and partitioning/clustering optimization.

See [README.md](README.md) for additional context.

## Tools

### Check BigQuery Table Size Trends for `${GCP_PROJECT_ID}`

Analyzes table sizes across all datasets to identify tables exceeding the configured size threshold.

- **Robot task name**: <code>Check BigQuery Table Size Trends for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_table_size_trends.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `data:metrics`, `access:read-only`
- **Reads**: `TABLE_SIZE_THRESHOLD_GB`
- **Writes**: `table_size_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Check BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`

Reviews IAM policies on all datasets to detect public access and overly permissive roles.

- **Robot task name**: <code>Check BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_dataset_access.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `security`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `dataset_access_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Check BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`

Identifies tables without expiration timestamps and datasets without default table expiration.

- **Robot task name**: <code>Check BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_table_expiration.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `retention`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `table_expiration_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Check BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`

Verifies that BigQuery audit logs and log sinks are configured for the project.

- **Robot task name**: <code>Check BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_audit_logging.sh`
- **Tags**: `gcp`, `bigquery`, `logging`, `auditing`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `audit_logging_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Analyze BigQuery Table Partitioning and Clustering for `${GCP_PROJECT_ID}`

Identifies large tables lacking partitioning or clustering for optimization and cost savings.

- **Robot task name**: <code>Analyze BigQuery Table Partitioning and Clustering for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_table_optimization.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `optimization`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `table_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Generate BigQuery Dataset Health Summary Report for `${GCP_PROJECT_ID}`

Produces a consolidated dataset health summary including total datasets, tables, storage, and largest tables.

- **Robot task name**: <code>Generate BigQuery Dataset Health Summary Report for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_dataset_summary.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `summary`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `dataset_summary.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

## Monitor

This SLI scores BigQuery dataset health by evaluating table sizes, access configuration, expiration policies, audit logging, and table optimization. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score BigQuery Table Size Trends for `${GCP_PROJECT_ID}`

Scores table sizes against the configured threshold. Returns 1 if no oversized tables, 0 otherwise.

- **Robot task name**: <code>Score BigQuery Table Size Trends for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `table_sizes`
- **Underlying script**: `check_table_size_trends.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `data:metrics`, `access:read-only`
- **Reads**: `TABLE_SIZE_THRESHOLD_GB`
- **Pass condition**: `int(${issues_output.stdout}) == 0`

#### Score BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`

Scores dataset access configuration. Returns 1 if no public or overly permissive access found.

- **Robot task name**: <code>Score BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `access_config`
- **Underlying script**: `check_dataset_access.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `security`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`

#### Score BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`

Scores table expiration policy coverage. Returns 1 if no tables or datasets lack expiration.

- **Robot task name**: <code>Score BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `expiration_policies`
- **Underlying script**: `check_table_expiration.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `retention`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`

#### Score BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`

Scores audit logging configuration. Returns 1 if audit logging is properly configured.

- **Robot task name**: <code>Score BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `audit_logging`
- **Underlying script**: `check_audit_logging.sh`
- **Tags**: `gcp`, `bigquery`, `logging`, `auditing`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`

#### Score BigQuery Table Optimization for `${GCP_PROJECT_ID}`

Scores table partitioning and clustering. Returns 1 if all large tables are properly optimized.

- **Robot task name**: <code>Score BigQuery Table Optimization for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `table_optimization`
- **Underlying script**: `check_table_optimization.sh`
- **Tags**: `gcp`, `bigquery`, `dataset`, `optimization`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing BigQuery resources. | — | yes |
| `TABLE_SIZE_THRESHOLD_GB` | string | Table size in GB above which an issue is raised. | `100` | no |
| `TABLE_GROWTH_THRESHOLD_PERCENT` | string | Month-over-month growth percentage that triggers an alert. | `50` | no |
| `INCLUDE_STREAMING_BUFFER` | string | Whether to include streaming buffer in table size calculations. | `false` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `table_size_issues.json`
- `dataset_access_issues.json`
- `table_expiration_issues.json`
- `audit_logging_issues.json`
- `table_optimization_issues.json`
- `dataset_summary.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-bigquery-dataset-health/runbook.robot`
- **Monitor**: `codebundles/gcp-bigquery-dataset-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-bigquery-dataset-health
export GCP_PROJECT_ID=...
export TABLE_SIZE_THRESHOLD_GB=...
export TABLE_GROWTH_THRESHOLD_PERCENT=...
export INCLUDE_STREAMING_BUFFER=...
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-bigquery-dataset-health
export GCP_PROJECT_ID=...
export TABLE_SIZE_THRESHOLD_GB=...
bash check_table_size_trends.sh
bash check_dataset_access.sh
bash check_table_expiration.sh
bash check_audit_logging.sh
bash check_table_optimization.sh
bash generate_dataset_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring
- `check_table_size_trends.sh` — analyzes table sizes
- `check_dataset_access.sh` — reviews IAM policies for public access
- `check_table_expiration.sh` — checks table and dataset expiration policies
- `check_audit_logging.sh` — verifies audit log configuration
- `check_table_optimization.sh` — checks partitioning and clustering
- `generate_dataset_summary.sh` — produces consolidated health summary