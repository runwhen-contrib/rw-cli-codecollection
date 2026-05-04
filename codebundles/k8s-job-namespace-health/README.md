# Kubernetes Namespace Job Health

This CodeBundle surfaces Kubernetes **Job** and **CronJob** reliability in one namespace: terminal failures, long-running active Jobs, warning events on Job-owned pods, suspended or stale CronJobs, and failed latest child Jobs.

## Overview

- **Job summary**: Counts active, succeeded, and failed Jobs; flags Jobs active longer than a configurable threshold and high concurrent active Job volume.
- **Failed Jobs**: Failed conditions, backoff-related failures, and unhealthy container state on Job pods.
- **Events**: Recent warning/non-normal events correlated to pods owned by Jobs.
- **CronJobs**: Suspended controllers, schedules that ran recently without a recorded success, and CronJobs whose most recently created child Job failed.

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context for API access.
- `NAMESPACE`: Namespace to evaluate.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `RW_LOOKBACK_WINDOW`: Window for event freshness and CronJob success checks, e.g. `24h` or `30m` (default: `24h`).
- `JOB_ACTIVE_DURATION_WARN_MINUTES`: Minutes an active Job may run before informational issues and SLI scoring treat it as problematic (default: `360`).

Workspace generation templates also support optional `custom` keys `rw_lookback_window` and `job_active_duration_warn_minutes` for defaults in RunWhen Local.

### Secrets

- `kubeconfig`: Standard kubeconfig YAML with **read-only** `list`/`get` on `jobs`, `cronjobs`, `pods`, and `events` in the target namespace (and cluster reachability).

## Tasks

### Summarize Job Status in Namespace

Aggregates Job completion signals and highlights long-running active Jobs or very high active Job counts.

### Identify Failed Jobs and Backoff in Namespace

Lists Jobs in a failed state, backoff exhaustion signals, and Job pods with waiting or failed containers.

### Correlate Job Failures with Recent Events in Namespace

Collects warning-oriented events for Job-owned pods within `RW_LOOKBACK_WINDOW`.

### Check CronJob Schedule Health in Namespace

Reports suspended CronJobs, potentially stale successes after recent schedules, and failed latest child Jobs per CronJob.

## SLI

`sli.robot` computes a **0–1** score from three dimensions: no failed Jobs, no overlong active Jobs, and CronJob reliability (no suspended CronJobs and no failed latest child Job per CronJob). The aggregate is the arithmetic mean.
