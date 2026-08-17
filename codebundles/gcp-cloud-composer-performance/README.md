# GCP Cloud Composer Performance & Capacity

Analyzes GCP Cloud Composer (Managed Airflow) worker, scheduler, and queue
utilization to detect over-provisioning, capacity shortfalls, and usage deltas
from a configurable "normal" baseline so environments run cost-efficiently
without sacrificing job health.

## Overview

This CodeBundle monitors the capacity and performance of Cloud Composer
environments in a GCP project. It focuses only on utilization and capacity
(deliberately paired with the `gcp-cloud-composer-health` bundle, which handles
broken/degraded environments and jobs). It pulls metrics from Google Cloud
Monitoring (via MQL on the Ops Suite / Monitoring API) and evaluates them
against configurable thresholds and windows:

- **Worker Utilization**: Flags workers that are consistently saturated (may
  cause task backlogs).
- **Scheduler and Queue Utilization**: Flags scheduler saturation and
  persistent task-instance queue backlogs that indicate insufficient capacity.
- **Over-Provisioning**: Flags environments that are consistently idle below
  the underutilization threshold while still paying for that capacity
  (eligible for scale-down).
- **Usage Deltas**: Flags significant deviation of current utilization/queue
  behavior from the same environment's rolling baseline (sudden spikes or
  sustained growth).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP Project ID that contains the Cloud Composer
  environments (e.g. `myproject-id`).

### Optional Variables

- `ENV_NAME`: Pin analysis to a single Composer environment name; defaults to
  `All` (auto-discover all environments in the project).
- `LOOKBACK_WINDOW_MINUTES`: Time range (minutes) of historical usage to
  evaluate (default: `1440`).
- `BASELINE_WINDOW_MINUTES`: Comparison window (minutes) used as the "normal"
  baseline for delta detection (default: `10080`).
- `UTILIZATION_THRESHOLD_PERCENT`: Upper utilization threshold (percent) above
  which capacity is considered saturated (default: `80`).
- `UNDERUTILIZATION_THRESHOLD_PERCENT`: Lower utilization threshold (percent)
  below which capacity is considered over-provisioned (default: `20`).
- `DELTA_THRESHOLD_PERCENT`: Percent deviation from baseline that triggers a
  usage-delta issue (default: `50`).
- `QUEUE_BACKLOG_THRESHOLD`: Average task-instance queue depth above which a
  persistent backlog is flagged (default: `100`).

SLI-specific variables:

- `SLI_WINDOW_MINUTES`: Time window (minutes) that the SLI evaluates (default:
  `60`).

### Secrets

- `gcp_credentials`: GCP service account JSON used to authenticate with GCP
  APIs. Format:
  ```json
  {
    "type": "service_account",
    "project_id": "myproject-id",
    "client_email": "sa@project.iam.gserviceaccount.com",
    "private_key": "-----BEGIN PRIVATE KEY-----..."
  }
  ```

## Tasks Overview

### Analyze Cloud Composer Worker Utilization for Environments in `${GCP_PROJECT_ID}`

Computes worker CPU/memory utilization and active task throughput over the
configured lookback window from Cloud Monitoring. Flags workers that are
consistently saturated and may cause task backlogs. Severity: 2-3.

### Analyze Cloud Composer Scheduler and Queue Utilization for Environments in `${GCP_PROJECT_ID}`

Measures scheduler heartbeat activity and the task-instance queue depth over
the window. Flags scheduler saturation or persistent queue backlogs that
indicate insufficient capacity. Severity: 2-3.

### Detect Cloud Composer Over-Provisioning for Environments in `${GCP_PROJECT_ID}`

Flags environments that are consistently far below the worker utilization
threshold (idle capacity) over the window while still paying for that capacity,
identifying candidates eligible for scale-down. Severity: 2.

### Detect Cloud Composer Usage Deltas Over Normal Baseline for Environments in `${GCP_PROJECT_ID}`

Compares current utilization and queue behavior against the rolling baseline
computed from the same environment's history over a configurable comparison
window. Flags significant deltas (sudden spikes or sustained growth) that
deviate from normal usage. Severity: 2-3.

## Permissions

The service account needs the following IAM permissions on the project:

- `monitoring.metricDescriptors.list`
- `monitoring.timeSeries.list`

The `roles/monitoring.viewer` role covers these. `roles/composer.viewer` (or
the ability to run `gcloud composer environments list`) is also required for
environment discovery.

## Notes

- Because "normal" is environment-specific, the delta baseline is computed from
  the same environment's history, not a global value.
- Thresholds and windows are configurable to avoid noise.
- This bundle intentionally focuses on capacity/utilization; coordinate with
  the `gcp-cloud-composer-health` bundle so broken environments are not double
  reported.
