---
name: gcp-cloud-sql-performance
kind: skill-template
description: Monitor GCP Cloud SQL instance performance and utilization. Use when triaging or monitoring GCP, Cloud SQL, SQL workloads with skill template `gcp-cloud-sql-performance`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud SQL]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud SQL Performance

## Summary

This codebundle monitors the performance of GCP Cloud SQL instances in a project. It reviews CPU/memory/disk utilization, throughput and IOPS performance, long-running queries, and storage growth via Cloud Monitoring metrics and instance logs, flagging instances that are over-utilized, perform poorly, or host long-running queries so operators can right-size instances and detect performance degradation before it becomes an availability incident.

See [README.md](README.md) for additional context.

## Tools

### Review Cloud SQL Instance Utilization in GCP Project `${GCP_PROJECT_ID}`

Evaluates CPU, memory, and disk utilization for each Cloud SQL instance via Cloud Monitoring metrics over the look-back window, flagging instances consistently above `CPU_THRESHOLD_PERCENT`.

- **Robot task name**: <code>Review Cloud SQL Instance Utilization in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `review_utilization.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `CPU_THRESHOLD_PERCENT`, `UTILIZATION_HOURS`
- **Writes**: `utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when instances exceed the CPU threshold

### Identify Cloud SQL Performance Issues in GCP Project `${GCP_PROJECT_ID}`

Analyzes throughput and IOPS metrics from Cloud Monitoring to flag instances with sustained high traffic, throughput spikes, or noisy traffic patterns over the look-back window.

- **Robot task name**: <code>Identify Cloud SQL Performance Issues in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_performance.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `UTILIZATION_HOURS`
- **Writes**: `performance_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when performance degradation is detected

### Identify Long Running Queries for Cloud SQL Instances in GCP Project `${GCP_PROJECT_ID}`

Queries Cloud SQL instance logs for queries whose duration exceeds `LONG_QUERY_SECONDS` and reports the offending SQL, degrading gracefully with a note when query logs are unavailable.

- **Robot task name**: <code>Identify Long Running Queries for Cloud SQL Instances in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `find_long_running_queries.sh`
- **Tags**: `gcloud`, `sql`, `logging`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-query`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `LONG_QUERY_SECONDS`
- **Writes**: `long_query_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when long-running queries are found

### Check Cloud SQL Instance Storage Growth in GCP Project `${GCP_PROJECT_ID}`

Compares used storage to configured capacity for each Cloud SQL instance and flags instances at risk of running out of disk, especially high-fill instances without automatic storage increase.

- **Robot task name**: <code>Check Cloud SQL Instance Storage Growth in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_storage_growth.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics-config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `STORAGE_FILL_THRESHOLD_PERCENT`, `UTILIZATION_HOURS`
- **Writes**: `storage_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when storage risk is detected

## Monitor

This SLI scores GCP Cloud SQL performance health by evaluating CPU utilization, throughput/noise performance, long-running queries, and storage headroom. Produces a value between 0 (completely failing) and 1 (fully healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Cloud SQL Utilization Health in `${GCP_PROJECT_ID}`

Scores 1.0 if no Cloud SQL instances are over the CPU utilization threshold, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud SQL Utilization Health in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `overutilized_instance_count`, `utilization`
- **Underlying script**: `review_utilization.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `CPU_THRESHOLD_PERCENT`, `UTILIZATION_HOURS`
- **Pass condition**: `int(${overutilized_instance_count}) == 0`

#### Score Cloud SQL Performance Health in `${GCP_PROJECT_ID}`

Scores 1.0 if no Cloud SQL instances show throughput spikes or performance issues, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud SQL Performance Health in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `performance_issue_count`, `performance`
- **Underlying script**: `analyze_performance.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `UTILIZATION_HOURS`
- **Pass condition**: `int(${performance_issue_count}) == 0`

#### Score Cloud SQL Long Running Query Health in `${GCP_PROJECT_ID}`

Scores 1.0 if no queries exceed `LONG_QUERY_SECONDS`, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud SQL Long Running Query Health in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `long_query_count`, `long_running_queries`
- **Underlying script**: `find_long_running_queries.sh`
- **Tags**: `gcloud`, `sql`, `logging`, `gcp`, `${GCP_PROJECT_ID}`, `data:logs-query`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `LONG_QUERY_SECONDS`
- **Pass condition**: `int(${long_query_count}) == 0`

#### Score Cloud SQL Storage Health in `${GCP_PROJECT_ID}`

Scores 1.0 if no Cloud SQL instances are at risk of running out of disk, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud SQL Storage Health in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `storage_risk_count`, `storage`
- **Underlying script**: `check_storage_growth.sh`
- **Tags**: `gcloud`, `sql`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics-config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `STORAGE_FILL_THRESHOLD_PERCENT`, `UTILIZATION_HOURS`
- **Pass condition**: `int(${storage_risk_count}) == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID that hosts the Cloud SQL instances to check. | — | yes |
| `RESOURCES` | string | Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to `All` (auto-discover all instances). | `All` | no |
| `CPU_THRESHOLD_PERCENT` | string | CPU utilization percentage above which an instance is flagged as over-utilized. | `80` | no |
| `UTILIZATION_HOURS` | string | Look-back window (hours) for utilization and performance metrics. | `6` | no |
| `LONG_QUERY_SECONDS` | string | Query duration (seconds) above which a query is considered long-running. | `300` | no |
| `STORAGE_FILL_THRESHOLD_PERCENT` | string | Storage fill percentage above which an instance without automatic storage increase is flagged. | `80` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics: `utilization`, `performance`, `long_running_queries`, `storage` plus raw counts (`overutilized_instance_count`, `performance_issue_count`, `long_query_count`, `storage_risk_count`)
- `utilization_issues.json`
- `performance_issues.json`
- `long_query_issues.json`
- `storage_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-sql-performance/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-sql-performance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-sql-performance
export GCP_PROJECT_ID=...
export RESOURCES=All
export CPU_THRESHOLD_PERCENT=80
export UTILIZATION_HOURS=6
export LONG_QUERY_SECONDS=300
export STORAGE_FILL_THRESHOLD_PERCENT=80
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-sql-performance
export GCP_PROJECT_ID=...
export RESOURCES=All
export CPU_THRESHOLD_PERCENT=80
export UTILIZATION_HOURS=6
export LONG_QUERY_SECONDS=300
export STORAGE_FILL_THRESHOLD_PERCENT=80
bash discover_sql_instances.sh
bash review_utilization.sh
bash analyze_performance.sh
bash find_long_running_queries.sh
bash check_storage_growth.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across four health dimensions
- `discover_sql_instances.sh` — auto-discovers Cloud SQL instances in the project
- `review_utilization.sh` — evaluates CPU, memory, and disk utilization via Cloud Monitoring
- `analyze_performance.sh` — analyzes throughput and IOPS metrics for performance issues
- `find_long_running_queries.sh` — queries Cloud SQL instance logs for long-running queries
- `check_storage_growth.sh` — checks storage fill levels and flags risk of running out of disk
