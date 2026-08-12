---
name: gcp-bigquery-job-health
kind: skill-template
description: Monitor BigQuery job execution health including success rates, error patterns, slow jobs, and slot contention. Use when triaging or monitoring GCP, BigQuery workloads with skill template `gcp-bigquery-job-health`.
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

# GCP BigQuery Job Health

## Summary

Monitors BigQuery job execution health by analyzing success/failure rates, error patterns, slow-running jobs, and slot contention. Helps operators identify failed queries, stuck jobs, and systemic issues affecting BigQuery workloads.

See [README.md](README.md) for additional context.

## Tools

### Check BigQuery Job Success Rate for `${GCP_PROJECT_ID}`

Queries `INFORMATION_SCHEMA.JOBS_BY_PROJECT` to calculate the job success rate over a configurable lookback window. Raises an issue if the success rate falls below the configured threshold.

- **Robot task name**: <code>Check BigQuery Job Success Rate for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_job_success_rate.sh`
- **Tags**: `GCP`, `BigQuery`, `Job Health`, `Success Rate`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `JOB_LOOKBACK_HOURS`, `SUCCESS_RATE_THRESHOLD`
- **Writes**: `job_success_rate_output.json`
- **Issues raised**: severity 3 when success rate drops below threshold

### Analyze Failed BigQuery Job Error Patterns for `${GCP_PROJECT_ID}`

Categorizes failed BigQuery jobs by error reason (quotaExceeded, invalidQuery, timeout, accessDenied, etc.) and raises issues for the most frequent error categories with targeted remediation guidance.

- **Robot task name**: <code>Analyze Failed BigQuery Job Error Patterns for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_failed_jobs.sh`
- **Tags**: `GCP`, `BigQuery`, `Error Analysis`, `Job Failures`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`, `JOB_LOOKBACK_HOURS`
- **Writes**: `failed_jobs_analysis_output.json`
- **Issues raised**: severity 2-3 per error category based on criticality (quotaExceeded=3, invalidQuery=2, etc.)

### Identify Slow Running BigQuery Jobs for `${GCP_PROJECT_ID}`

Detects BigQuery jobs that exceed a configurable duration threshold via `INFORMATION_SCHEMA.JOBS_BY_PROJECT`. Raises issues based on count: severity 4 (>20 jobs), severity 3 (>5 jobs), severity 2 (isolated cases).

- **Robot task name**: <code>Identify Slow Running BigQuery Jobs for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `identify_slow_jobs.sh`
- **Tags**: `GCP`, `BigQuery`, `Performance`, `Slow Jobs`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `JOB_LOOKBACK_HOURS`, `SLOW_JOB_DURATION_MINUTES`
- **Writes**: `slow_jobs_output.json`
- **Issues raised**: severity 2-4 based on number of slow jobs detected

### Check BigQuery Job Slot Contention for `${GCP_PROJECT_ID}`

Analyzes slot usage from `INFORMATION_SCHEMA.JOBS_TIMELINE` to detect contention periods where slot demand exceeds reservation capacity.

- **Robot task name**: <code>Check BigQuery Job Slot Contention for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_slot_contention.sh`
- **Tags**: `GCP`, `BigQuery`, `Slot Contention`, `Performance`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `JOB_LOOKBACK_HOURS`, `SLOT_CONTENTION_THRESHOLD`
- **Writes**: `slot_contention_output.json`
- **Issues raised**: severity 3 (>10 contention periods) or severity 2 (minor contention)

## Monitor

This SLI scores BigQuery job health by evaluating job success rate, slow job count, and slot contention. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Check BigQuery Job Success Rate Score for `${GCP_PROJECT_ID}`

Checks the job success rate and scores 1 if above threshold, 0 otherwise.

- **Robot task name**: <code>Check BigQuery Job Success Rate Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `job_success_rate`
- **Underlying script**: `check_job_success_rate.sh`
- **Tags**: `GCP`, `BigQuery`, `Job Health`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `SUCCESS_RATE_THRESHOLD`, `JOB_LOOKBACK_HOURS`
- **Pass condition**: success rate at or above threshold

#### Check Slow Jobs Score for `${GCP_PROJECT_ID}`

Checks for slow running jobs and scores 1 if none found, 0 otherwise.

- **Robot task name**: <code>Check Slow Jobs Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `slow_jobs`
- **Underlying script**: `identify_slow_jobs.sh`
- **Tags**: `GCP`, `BigQuery`, `Performance`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `SLOW_JOB_DURATION_MINUTES`, `JOB_LOOKBACK_HOURS`
- **Pass condition**: no jobs exceed the configured duration threshold

#### Check Slot Contention Score for `${GCP_PROJECT_ID}`

Checks for slot contention and scores 1 if none found, 0 otherwise.

- **Robot task name**: <code>Check Slot Contention Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `slot_contention`
- **Underlying script**: `check_slot_contention.sh`
- **Tags**: `GCP`, `BigQuery`, `Slot Contention`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `SLOT_CONTENTION_THRESHOLD`, `JOB_LOOKBACK_HOURS`
- **Pass condition**: no slot contention periods detected

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP project ID that contains the BigQuery jobs to monitor. | — | yes |
| `JOB_LOOKBACK_HOURS` | string | Number of hours to look back for job analysis. | `24` | no |
| `SUCCESS_RATE_THRESHOLD` | string | Minimum acceptable job success rate (percentage). | `95` | no |
| `SLOW_JOB_DURATION_MINUTES` | string | Duration in minutes above which a job is considered slow. | `30` | no |
| `SLOT_CONTENTION_THRESHOLD` | string | Slot-milliseconds per hour above which contention is flagged. | `1000000` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics: `job_success_rate`, `slow_jobs`, `slot_contention`
- `job_success_rate_output.json`
- `failed_jobs_analysis_output.json`
- `slow_jobs_output.json`
- `slot_contention_output.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-bigquery-job-health/runbook.robot`
- **Monitor**: `codebundles/gcp-bigquery-job-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-bigquery-job-health
export GCP_PROJECT_ID=...
export JOB_LOOKBACK_HOURS=24
export SUCCESS_RATE_THRESHOLD=95
export SLOW_JOB_DURATION_MINUTES=30
export SLOT_CONTENTION_THRESHOLD=1000000
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-bigquery-job-health
export GCP_PROJECT_ID=...
export JOB_LOOKBACK_HOURS=24
export SUCCESS_RATE_THRESHOLD=95
export SLOW_JOB_DURATION_MINUTES=30
export SLOT_CONTENTION_THRESHOLD=1000000
bash check_job_success_rate.sh
bash analyze_failed_jobs.sh
bash identify_slow_jobs.sh
bash check_slot_contention.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across three health dimensions (success rate, slow jobs, slot contention)
- `check_job_success_rate.sh` — queries INFORMATION_SCHEMA for job success/failure rates
- `analyze_failed_jobs.sh` — categorizes failed jobs by error reason with severity mapping
- `identify_slow_jobs.sh` — detects jobs exceeding the configured duration threshold
- `check_slot_contention.sh` — analyzes slot utilization from JOBS_TIMELINE for contention
