---
name: gcp-cloud-composer-performance
kind: skill-template
description: Analyzes GCP Cloud Composer (Managed Airflow) worker, scheduler, and queue utilization to detect over-provisioning,... Use when triaging or monitoring GCP, Cloud Composer, Airflow workloads with sk...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Composer, Airflow, Performance, Capacity, Utilization, Monitoring]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Composer Performance & Capacity

## Summary

Analyzes GCP Cloud Composer (Managed Airflow) worker, scheduler, and queue utilization to detect over-provisioning, capacity shortfalls, and usage deltas.

See [README.md](README.md) for additional context.

## Tools

### Analyze Cloud Composer Worker Utilization for Environments in `${GCP_PROJECT_ID}`

Computes worker CPU/memory utilization and active task throughput over the configured lookback window from Cloud Monitoring, flagging workers that are consistently saturated and may cause task backlogs.

- **Robot task name**: <code>Analyze Cloud Composer Worker Utilization for Environments in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_worker_utilization.sh`
- **Tags**: `GCP`, `Composer`, `Worker`, `Utilization`, `Capacity`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `worker_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Cloud Composer Scheduler and Queue Utilization for Environments in `${GCP_PROJECT_ID}`

Measures scheduler heartbeat activity and the task-instance queue depth over the window, flagging scheduler saturation or persistent queue backlogs that indicate insufficient capacity.

- **Robot task name**: <code>Analyze Cloud Composer Scheduler and Queue Utilization for Environments in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_scheduler_and_queues.sh`
- **Tags**: `GCP`, `Composer`, `Scheduler`, `Queue`, `Backlog`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `scheduler_queue_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Cloud Composer Over-Provisioning for Environments in `${GCP_PROJECT_ID}`

Flags environments that are consistently far below the worker utilization threshold (idle capacity) over the window while still paying for that capacity, identifying candidates eligible for scale-down.

- **Robot task name**: <code>Detect Cloud Composer Over-Provisioning for Environments in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `detect_overprovisioning.sh`
- **Tags**: `GCP`, `Composer`, `Overprovisioning`, `Cost`, `Idle`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `overprovisioning_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Cloud Composer Usage Deltas Over Normal Baseline for Environments in `${GCP_PROJECT_ID}`

Compares current utilization and queue behavior against the rolling baseline computed from the same environment's history over a configurable comparison window, flagging significant deltas such as sudden spikes or sustained growth that deviate from normal usage.

- **Robot task name**: <code>Detect Cloud Composer Usage Deltas Over Normal Baseline for Environments in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `detect_usage_deltas.sh`
- **Tags**: `GCP`, `Composer`, `UsageDelta`, `Baseline`, `Trend`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `usage_delta_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures the performance and capacity health of GCP Cloud Composer environments by scoring worker capacity, queue health, and utilization balance into a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Compute Cloud Composer Performance Dimensions for `${GCP_PROJECT_ID}`

Computes the worker capacity, queue health, and utilization balance dimension scores by querying Cloud Monitoring for the configured window.

- **Robot task name**: <code>Compute Cloud Composer Performance Dimensions for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `worker_capacity`
- **Underlying script**: `compute_composer_sli.sh`
- **Tags**: `GCP`, `Composer`, `Performance`, `SLI`, `data:metrics`, `access:read-only`
- **Reads**: `ENV_NAME`, `GCP_PROJECT_ID`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID that contains the Cloud Composer environments. | — | yes |
| `ENV_NAME` | string | Optional: pin analysis to a single Composer environment name; defaults to All (auto-discover). | `All` | no |
| `LOOKBACK_WINDOW_MINUTES` | string | Time range (minutes) of historical usage to evaluate. | `1440` | no |
| `BASELINE_WINDOW_MINUTES` | string | Comparison window (minutes) used as the normal baseline for delta detection. | `10080` | no |
| `UTILIZATION_THRESHOLD_PERCENT` | string | Upper utilization threshold (percent) above which capacity is considered saturated. | `80` | no |
| `UNDERUTILIZATION_THRESHOLD_PERCENT` | string | Lower utilization threshold (percent) below which capacity is considered over-provisioned. | `20` | no |
| `DELTA_THRESHOLD_PERCENT` | string | Percent deviation from baseline that triggers a usage-delta issue. | `50` | no |
| `QUEUE_BACKLOG_THRESHOLD` | string | Average task-instance queue depth above which a persistent backlog is flagged. | `100` | no |
| `SLI_WINDOW_MINUTES` | string | Time window (minutes) of usage the SLI evaluates. | `60` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `worker_utilization_issues.json`
- `scheduler_queue_issues.json`
- `overprovisioning_issues.json`
- `usage_delta_issues.json`
- `composer_sli.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-composer-performance/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-composer-performance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-composer-performance
export GCP_PROJECT_ID=...
export ENV_NAME=...
export LOOKBACK_WINDOW_MINUTES=...
export BASELINE_WINDOW_MINUTES=...
export UTILIZATION_THRESHOLD_PERCENT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-composer-performance
export GCP_PROJECT_ID=...
export ENV_NAME=...
export LOOKBACK_WINDOW_MINUTES=...
bash analyze_scheduler_and_queues.sh
bash analyze_worker_utilization.sh
bash composer_metrics_common.sh
bash compute_composer_sli.sh
bash detect_overprovisioning.sh
bash detect_usage_deltas.sh
bash discover_composer_environments.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_scheduler_and_queues.sh` — Bash helper script `analyze_scheduler_and_queues.sh`.
- `analyze_worker_utilization.sh` — Bash helper script `analyze_worker_utilization.sh`.
- `composer_metrics_common.sh` — Bash helper script `composer_metrics_common.sh`.
- `compute_composer_sli.sh` — Bash helper script `compute_composer_sli.sh`.
- `detect_overprovisioning.sh` — Bash helper script `detect_overprovisioning.sh`.
- `detect_usage_deltas.sh` — Bash helper script `detect_usage_deltas.sh`.
- `discover_composer_environments.sh` — Bash helper script `discover_composer_environments.sh`.
