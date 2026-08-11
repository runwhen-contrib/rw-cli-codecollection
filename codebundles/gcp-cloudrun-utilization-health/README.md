# GCP Cloud Run Utilization & Scaling Health

Monitors resource utilization and scaling configuration of GCP Cloud Run
services per project, flagging services that are over-provisioned
(under-utilized), over-utilized (approaching limits), or improperly scaled
(unbounded max instances, low concurrency targets, idle-warming min-instances).
It captures utilization metrics and scaling configuration into the report for
LLM-based cost and sizing review.

## Overview

This CodeBundle checks the health of Cloud Run services from a cost and sizing
perspective:

- **CPU utilization**: flags services at or above the CPU threshold (over-utilized)
- **Memory utilization**: flags services at or above the memory threshold (OOM risk)
- **Concurrency & scaling**: flags unbounded max instances, very low concurrency targets, and min-instances settings that keep idle instances warm
- **Under-utilization**: flags services with sustained near-zero CPU utilization that could be right-sized or scaled to zero
- **Utilization report**: captures CPU/memory utilization and scaling configuration for every service for LLM review

It complements `gcp-cloudrun-service-health` (availability) and
`gcp-project-cost-health` (project-level cost), and overlaps with
`gcp-cloud-function-health` (which covers gen2 functions; this bundle covers
standalone Cloud Run services).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP Project ID to scope the API to. Example: `my-gcp-project`

### Optional Variables

- `RESOURCES`: Comma-separated Cloud Run service names to check, or `All` to
  auto-discover all services in the project. (default: `All`)
- `METRIC_LOOKBACK_PERIOD`: Lookback window for monitoring metrics, e.g.
  `3600s`. (default: `3600s`)
- `CPU_UTILIZATION_THRESHOLD`: High CPU utilization percentage threshold above
  which a service is flagged as over-utilized. (default: `80`)
- `MEMORY_UTILIZATION_THRESHOLD`: High memory utilization percentage threshold
  above which a service is flagged for OOM risk. (default: `85`)
- `MIN_UTILIZATION_THRESHOLD`: Low utilization percentage below which a service
  is considered under-utilized. (default: `10`)

### Secrets

- `gcp_credentials`: GCP service account JSON used to authenticate with GCP
  APIs, e.g. `{"type": "service_account", "project_id": "...",
  "client_email": "...", "private_key": "..."}`.

## SLI

The SLI produces a binary health score: **1** only if every health dimension
passes, **0** if any is degraded. Dimensions scored (each pushed as a sub-metric
with its raw issue count):

- **CPU utilization** — no service at/above the CPU threshold
- **Memory utilization** — no service at/above the memory threshold (OOM risk)
- **Scaling configuration** — no unbounded max instances, very low concurrency, or idle-warming min-instances

## Tasks Overview

### Check Cloud Run Service CPU Utilization in GCP Project

Reads container CPU utilization (`run.googleapis.com/container/cpu/utilizations`)
for each service and flags services at or above `CPU_UTILIZATION_THRESHOLD`,
indicating over-utilization. Writes `cpu_utilization_issues.json`. Severity 3.

### Check Cloud Run Service Memory Utilization in GCP Project

Reads container memory utilization (`run.googleapis.com/container/memory/utilizations`)
and flags services at or above `MEMORY_UTILIZATION_THRESHOLD`, indicating OOM
risk. Writes `memory_utilization_issues.json`. Severity 3.

### Check Cloud Run Service Request Concurrency and Instance Scaling

Reviews target concurrency and instance scaling settings, flagging unbounded
max instances (severity 3), very low concurrency targets (severity 2), and
min-instances settings that keep idle instances warm (severity 2). Writes
`concurrency_scaling_issues.json`.

### Identify Under-Utilized Cloud Run Services

Identifies services with sustained CPU utilization below `MIN_UTILIZATION_THRESHOLD`,
surfacing over-provisioned/idle services that could be right-sized or scaled to
zero. Writes `underutilized_issues.json`. Severity 2.

### Report Cloud Run Utilization and Scaling Configuration

Captures CPU/memory utilization and scaling configuration for all Cloud Run
services into `utilization_report.json` and adds it to the report for LLM-based
cost and sizing review. Raises no issues.

## Requirements

The following permissions are required on the GCP service account used with the
gcloud utility:

- `run.services.get`
- `run.services.list`
- `monitoring.timeSeries.list`

Artemis/enabled APIs: Cloud Run Admin API and Cloud Monitoring API on the scoped
project. Service account JSON is passed via the `gcp_credentials` secret.
