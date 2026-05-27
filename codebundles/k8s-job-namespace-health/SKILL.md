---
name: k8s-job-namespace-health
description: Surfaces Kubernetes Job and CronJob health in a namespace: failed or long-running Jobs, pod events, and CronJob... Use when triaging or monitoring Kubernetes, Job, CronJob workloads with skill temp...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, Job, CronJob, batch, Namespace, Health]
resource_types: [namespace]
access: read-only
---

# Kubernetes Namespace Job Health

## Summary

This CodeBundle surfaces Kubernetes **Job** and **CronJob** reliability in one namespace: terminal failures, long-running active Jobs, warning events on Job-owned pods, suspended or stale CronJobs, and failed latest child Jobs.

See [README.md](README.md) for additional context.

## Tools

### Summarize Job Status in Namespace `${NAMESPACE}`

Aggregates Jobs by active, succeeded, and failed completion state and flags long-running active Jobs or elevated batch concurrency in the namespace.

- **Robot task name**: <code>Summarize Job Status in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `summarize-jobs-in-namespace.sh`
- **Tags**: `Kubernetes`, `Job`, `Namespace`, `batch`, `summary`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `NAMESPACE`
- **Writes**: `summarize_jobs_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Failed Jobs and Backoff in Namespace `${NAMESPACE}`

Lists Jobs in Failed condition, backoff exhaustion, and Job pods with container waiting or non-zero exit states.

- **Robot task name**: <code>Identify Failed Jobs and Backoff in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `list-failed-jobs-in-namespace.sh`
- **Tags**: `Kubernetes`, `Job`, `failed`, `backoff`, `access:read-only`, `data:logs-config`
- **Reads**: `CONTEXT`, `NAMESPACE`
- **Writes**: `list_failed_jobs_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Correlate Job Failures with Recent Events in Namespace `${NAMESPACE}`

Collects warning and failure-oriented events for pods owned by Jobs within the configured lookback window.

- **Robot task name**: <code>Correlate Job Failures with Recent Events in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `job-failure-events-in-namespace.sh`
- **Tags**: `Kubernetes`, `Job`, `events`, `access:read-only`, `data:logs-config`
- **Reads**: `CONTEXT`, `NAMESPACE`
- **Writes**: `job_failure_events_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check CronJob Schedule Health in Namespace `${NAMESPACE}`

Flags suspended CronJobs, schedules that ran recently without a recorded success, and CronJobs whose latest child Job failed.

- **Robot task name**: <code>Check CronJob Schedule Health in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cronjob-schedule-health-in-namespace.sh`
- **Tags**: `Kubernetes`, `CronJob`, `schedule`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `NAMESPACE`
- **Writes**: `cronjob_health_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures namespace Job and CronJob health with lightweight kubectl checks. Produces a value between 0 (failing) and 1 (healthy) from the mean of binary sub-scores.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Failed Jobs Dimension for Namespace `${NAMESPACE}`

1 when no Job has a Failed=True condition; 0 otherwise.

- **Robot task name**: <code>Score Failed Jobs Dimension for Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `failed_jobs`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${n} == 0`


#### Score Long-Running Active Jobs for Namespace `${NAMESPACE}`

1 when no active Job exceeds JOB_ACTIVE_DURATION_WARN_MINUTES based on status.startTime.

- **Robot task name**: <code>Score Long-Running Active Jobs for Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `long_running_active`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `JOB_ACTIVE_DURATION_WARN_MINUTES`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${n} == 0`


#### Score CronJob Reliability for Namespace `${NAMESPACE}`

1 when no CronJob is suspended and no latest CronJob-owned Job is in Failed=True state.

- **Robot task name**: <code>Score CronJob Reliability for Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `cronjob_reliability`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `(${ns} == 0 and ${nf} == 0)`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Kubernetes CLI binary (kubectl or oc). | `kubectl` | no |
| `CONTEXT` | string | Kubernetes context for API calls. | — | yes |
| `NAMESPACE` | string | Namespace whose Job and CronJob health is evaluated. | — | yes |
| `RW_LOOKBACK_WINDOW` | string | Lookback window for events and CronJob freshness (e.g. 24h, 30m). | `24h` | no |
| `JOB_ACTIVE_DURATION_WARN_MINUTES` | string | Flag active Jobs running longer than this many minutes. | `360` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `summarize_jobs_issues.json`
- `list_failed_jobs_issues.json`
- `job_failure_events_issues.json`
- `cronjob_health_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-job-namespace-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export RW_LOOKBACK_WINDOW=...
export JOB_ACTIVE_DURATION_WARN_MINUTES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-job-namespace-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export RW_LOOKBACK_WINDOW=...
bash cronjob-schedule-health-in-namespace.sh
bash job-failure-events-in-namespace.sh
bash list-failed-jobs-in-namespace.sh
bash summarize-jobs-in-namespace.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `cronjob-schedule-health-in-namespace.sh` — Bash helper script `cronjob-schedule-health-in-namespace.sh`.
- `job-failure-events-in-namespace.sh` — Bash helper script `job-failure-events-in-namespace.sh`.
- `list-failed-jobs-in-namespace.sh` — Bash helper script `list-failed-jobs-in-namespace.sh`.
- `summarize-jobs-in-namespace.sh` — Bash helper script `summarize-jobs-in-namespace.sh`.
