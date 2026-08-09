---
name: gcp-cloudspanner-instance-health
kind: skill-template
description: Monitors GCP Cloud Spanner instance and database health — state, high-priority CPU, storage utilization, latency/errors. Use when triaging or monitoring GCP, Spanner workloads with skill template `gcp-cloudspanner-instance-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Spanner]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Spanner Instance Health

## Summary

Monitors the operational health of GCP Cloud Spanner instances and their databases — instance/database state, high-priority CPU utilization, storage utilization against per-node/processing-unit limits, and request latency/errors.

See [README.md](README.md) for additional context.

## Tools

### Check Cloud Spanner Instance State and Configuration for `${GCP_PROJECT_ID}`

Verifies each Cloud Spanner instance is in READY state, reports node_count/processing_units and instance config (regional vs multi-region), and flags multi-region instances under-provisioned for their config.

- **Robot task name**: <code>Check Cloud Spanner Instance State and Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_state.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `config`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `instance_state_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`

Reads high-priority CPU utilization from Cloud Monitoring and flags instances above the config-derived threshold (65% regional, 45% multi-region by default).

- **Robot task name**: <code>Check Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_cpu_utilization.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `cpu`, `data:metrics`, `access:read-only`
- **Reads**: `CPU_UTILIZATION_THRESHOLD`, `MULTI_REGION_CPU_UTILIZATION_THRESHOLD`
- **Writes**: `cpu_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`

Compares storage used against each instance's storage limit (derived from node/processing-unit count) and flags instances approaching the limit.

- **Robot task name**: <code>Check Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_storage_utilization.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `storage`, `data:metrics`, `access:read-only`
- **Reads**: `STORAGE_LIMIT_GB_PER_NODE`, `STORAGE_UTILIZATION_THRESHOLD`
- **Writes**: `storage_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Database State for `${GCP_PROJECT_ID}`

Lists databases per instance, verifies each is READY, and flags long-running schema/DDL operations or databases stuck in CREATING.

- **Robot task name**: <code>Check Cloud Spanner Database State for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_database_state.sh`
- **Tags**: `gcp`, `spanner`, `database`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `database_state_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Cloud Spanner Request Latency and Errors for `${GCP_PROJECT_ID}`

Pulls read/write request latency and error/abort rates from Cloud Monitoring and flags instances exceeding latency or error-rate thresholds.

- **Robot task name**: <code>Analyze Cloud Spanner Request Latency and Errors for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_latency_errors.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `latency`, `errors`, `data:metrics`, `access:read-only`
- **Reads**: `ERROR_RATE_THRESHOLD_PERCENT`, `LATENCY_THRESHOLD_MS`
- **Writes**: `latency_errors_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures the health of Cloud Spanner instances by scoring instance state, high-priority CPU utilization, storage utilization, and database state. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Cloud Spanner Instance State for `${GCP_PROJECT_ID}`

Scores instance state/configuration. Returns 1 if no instances are unready or under-provisioned.

- **Robot task name**: <code>Score Cloud Spanner Instance State for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `instance_state`
- **Underlying script**: `check_instance_state.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `config`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`

Scores high-priority CPU utilization against the config-derived threshold. Returns 1 if no instance exceeds it.

- **Robot task name**: <code>Score Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `cpu_utilization`
- **Underlying script**: `check_cpu_utilization.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `cpu`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`

Scores storage utilization against the node/PU-derived limit. Returns 1 if no instance is approaching its limit.

- **Robot task name**: <code>Score Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `storage_utilization`
- **Underlying script**: `check_storage_utilization.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `storage`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Database State for `${GCP_PROJECT_ID}`

Scores database state and long-running DDL operations. Returns 1 if no database issues are found.

- **Robot task name**: <code>Score Cloud Spanner Database State for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `database_state`
- **Underlying script**: `check_database_state.sh`
- **Tags**: `gcp`, `spanner`, `database`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing the Cloud Spanner instances. | — | yes |
| `CPU_UTILIZATION_THRESHOLD` | string | High-priority CPU utilization percent (regional instances) above which an issue is raised. | `65` | no |
| `MULTI_REGION_CPU_UTILIZATION_THRESHOLD` | string | High-priority CPU utilization percent (multi-region instances) above which an issue is raised. | `45` | no |
| `STORAGE_UTILIZATION_THRESHOLD` | string | Storage % of the node/processing-unit-derived limit above which an issue is raised. | `75` | no |
| `STORAGE_LIMIT_GB_PER_NODE` | string | Spanner storage limit in GB per node (or per 1000 processing units), used to derive each instance's storage limit. | `4096` | no |
| `LATENCY_THRESHOLD_MS` | string | Request latency (ms) above which an issue is raised. | `100` | no |
| `ERROR_RATE_THRESHOLD_PERCENT` | string | Request error/abort rate percent above which an issue is raised. | `1` | no |
| `LONG_RUNNING_OPERATION_MINUTES` | string | Age in minutes above which an incomplete schema/DDL operation is flagged. | `60` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Monitoring Viewer roles. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `instance_state_issues.json`
- `cpu_utilization_issues.json`
- `storage_utilization_issues.json`
- `database_state_issues.json`
- `latency_errors_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloudspanner-instance-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloudspanner-instance-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloudspanner-instance-health
export GCP_PROJECT_ID=...
export CPU_UTILIZATION_THRESHOLD=...
export MULTI_REGION_CPU_UTILIZATION_THRESHOLD=...
export STORAGE_UTILIZATION_THRESHOLD=...
export STORAGE_LIMIT_GB_PER_NODE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloudspanner-instance-health
export GCP_PROJECT_ID=...
export CPU_UTILIZATION_THRESHOLD=...
export MULTI_REGION_CPU_UTILIZATION_THRESHOLD=...
bash analyze_latency_errors.sh
bash check_cpu_utilization.sh
bash check_database_state.sh
bash check_instance_state.sh
bash check_storage_utilization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_latency_errors.sh` — Bash helper script `analyze_latency_errors.sh`.
- `check_cpu_utilization.sh` — Bash helper script `check_cpu_utilization.sh`.
- `check_database_state.sh` — Bash helper script `check_database_state.sh`.
- `check_instance_state.sh` — Bash helper script `check_instance_state.sh`.
- `check_storage_utilization.sh` — Bash helper script `check_storage_utilization.sh`.
- `monitoring_query.sh` — shared helper sourced by the check scripts; queries Cloud Monitoring time series via the REST API (`gcloud monitoring time-series` does not exist).
