---
name: azure-adf-health
kind: skill-template
description: Azure Data Factories health checks including resource health status, frequent pipeline errors, failed pipeline runs,... Use when triaging or monitoring Azure, Data, factories workloads with skill t...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, Data, factories]
resource_types: [data_factory]
access: read-only
---

# Azure Data factories Health

## Summary

This codebundle runs a suite of metrics checks for Data Factory in Azure.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Fetch health status for all Data Factories in the resource group

- **Robot task name**: <code>Check for Resource Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `resource_health.sh`
- **Tags**: `datafactory`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

List frequently occurring errors in Data Factory pipelines

- **Robot task name**: <code>List Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `error_trend.sh`
- **Tags**: `datafactory`, `pipeline-errors`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AZURE_RESOURCE_GROUP`, `FAILURE_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

List failed pipeline runs in Data Factory pipelines

- **Robot task name**: <code>List Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `failed_pipeline.sh`
- **Tags**: `datafactory`, `pipeline-failures`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Find Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

List large data operations in Data Factory pipelines

- **Robot task name**: <code>Find Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `data_volume_audit.sh`
- **Tags**: `datafactory`, `data-volume`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Azure Data Factory Details in resource group `${AZURE_RESOURCE_GROUP}`

List comprehensive details about Azure Data Factories

- **Robot task name**: <code>Fetch Azure Data Factory Details in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `adf_details.sh`
- **Tags**: —
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

List long running pipeline runs in Data Factory pipelines

- **Robot task name**: <code>List Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `long_pipeline_runs.sh`
- **Tags**: `datafactory`, `long-running-pipelines`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Azure Data Factories health checks including resource health status, frequent pipeline errors, failed pipeline runs, and large data operations monitoring.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Identify Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Fetch health status for all Data Factories in the resource group

- **Robot task name**: <code>Identify Health Issues Affecting Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `resource_health.sh`
- **Tags**: `datafactory`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: —


#### Count Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Count frequently occurring errors in Data Factory pipelines

- **Robot task name**: <code>Count Frequent Pipeline Errors in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `pipeline_errors`
- **Underlying script**: `error_trend.sh`
- **Tags**: `datafactory`, `pipeline-errors`, `access:read-only`, `data:logs-regexp`
- **Reads**: —
- **Pass condition**: `${error_count} == 0`


#### Count Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Count failed pipeline runs in Data Factory pipelines

- **Robot task name**: <code>Count Failed Pipelines in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `failed_pipelines`
- **Underlying script**: `failed_pipeline.sh`
- **Tags**: `datafactory`, `pipeline-failures`, `access:read-only`, `data:logs-regexp`
- **Reads**: —
- **Pass condition**: `${failed_count} == 0`


#### Count Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Count large data operations in Data Factory pipelines

- **Robot task name**: <code>Count Large Data Operations in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `data_operations`
- **Underlying script**: `data_volume_audit.sh`
- **Tags**: `datafactory`, `data-volume`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${data_volume_alerts_count} == 0`


#### Count Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`

Count long running pipeline runs in Data Factory pipelines

- **Robot task name**: <code>Count Long Running Pipeline Runs in Data Factories in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `long_running_pipelines`
- **Underlying script**: `long_pipeline_runs.sh`
- **Tags**: `datafactory`, `pipeline-long-running`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${long_running_count} == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `AZURE_RESOURCE_GROUP` | string | Azure resource group. | — | yes |
| `LOOKBACK_PERIOD` | string | The lookback period for querying failed pipelines (e.g., 1d, 7d, 30d). | `7d` | no |
| `THRESHOLD_MB` | string | The threshold for data volume in MB. | `1000` | no |
| `FAILURE_THRESHOLD` | string | The threshold for failure count. | `1` | no |
| `RUN_TIME_THRESHOLD` | string | The threshold for run time of a pipeline in seconds. | `600` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-adf-health
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_RESOURCE_GROUP=...
export LOOKBACK_PERIOD=...
export THRESHOLD_MB=...
export FAILURE_THRESHOLD=...
export RUN_TIME_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-adf-health
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_RESOURCE_GROUP=...
export LOOKBACK_PERIOD=...
export THRESHOLD_MB=...
bash adf_details.sh
bash data_volume_audit.sh
bash error_trend.sh
bash failed_pipeline.sh
bash long_pipeline_runs.sh
bash resource_health.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `adf_details.sh` — Bash helper script `adf_details.sh`.
- `data_volume_audit.sh` — Bash helper script `data_volume_audit.sh`.
- `error_trend.sh` — Bash helper script `error_trend.sh`.
- `failed_pipeline.sh` — Bash helper script `failed_pipeline.sh`.
- `long_pipeline_runs.sh` — Bash helper script `long_pipeline_runs.sh`.
- `resource_health.sh` — Bash helper script `resource_health.sh`.
