---
name: gcp-cloudrun-utilization-health
kind: skill-template
description: Identify utilization, scaling, and cost problems in GCP Cloud Run services -- over-provisioned (under-utilized), over-utilized (approaching limits), or improperly scaled (unbounded max instances, low concurrency, idle-warming min-instances). Use when triaging or monitoring GCP Cloud Run utilization and scaling health with skill template `gcp-cloudrun-utilization-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Run]
resource_types: [gcp_run_services]
access: read-only
---

# GCP Cloud Run Utilization & Scaling Health

## Summary

Monitors GCP Cloud Run services for over-utilization (CPU/memory approaching
limits), mis-scaled configurations (unbounded max instances, low concurrency,
min-instances keeping idle instances warm), and under-utilization (over-
provisioned/idle services). Captures utilization metrics and scaling config for
LLM-based cost and sizing review.

See [README.md](README.md) for additional context.

## Tools

### Check Cloud Run Service CPU Utilization in GCP Project `${GCP_PROJECT_ID}`

Reads container CPU utilization for each service and flags services at or above
the CPU threshold, indicating over-utilization.

- **Robot task name**: <code>Check Cloud Run Service CPU Utilization in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_cpu_utilization.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `METRIC_LOOKBACK_PERIOD`, `CPU_UTILIZATION_THRESHOLD`
- **Writes**: `cpu_utilization_issues.json`
- **Issues raised**: severity 3 per over-utilized service

### Check Cloud Run Service Memory Utilization in GCP Project `${GCP_PROJECT_ID}`

Reads container memory utilization for each service and flags services at or
above the memory threshold (OOM risk).

- **Robot task name**: <code>Check Cloud Run Service Memory Utilization in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_memory_utilization.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `METRIC_LOOKBACK_PERIOD`, `MEMORY_UTILIZATION_THRESHOLD`
- **Writes**: `memory_utilization_issues.json`
- **Issues raised**: severity 3 per service at OOM risk

### Check Cloud Run Service Request Concurrency and Instance Scaling in GCP Project `${GCP_PROJECT_ID}`

Reviews target concurrency and instance scaling settings, flagging unbounded max
instances, very low concurrency targets, and min-instances keeping idle
instances warm.

- **Robot task name**: <code>Check Cloud Run Service Request Concurrency and Instance Scaling in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_concurrency_scaling.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `concurrency_scaling_issues.json`
- **Issues raised**: severity 3 (unbounded max instances) / severity 2 (low concurrency, min-instances warm)

### Identify Under-Utilized Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`

Identifies services with sustained near-zero utilization, surfacing
over-provisioned/idle services that could be right-sized or scaled to zero.

- **Robot task name**: <code>Identify Under-Utilized Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `find_underutilized_services.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `METRIC_LOOKBACK_PERIOD`, `MIN_UTILIZATION_THRESHOLD`
- **Writes**: `underutilized_issues.json`
- **Issues raised**: severity 2 per under-utilized service

### Report Cloud Run Utilization and Scaling Configuration for GCP Project `${GCP_PROJECT_ID}`

Captures utilization metrics and scaling configuration for all Cloud Run
services into the report for LLM-based cost and sizing review.

- **Robot task name**: <code>Report Cloud Run Utilization and Scaling Configuration for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `capture_utilization_report.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics-config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `METRIC_LOOKBACK_PERIOD`
- **Writes**: `utilization_report.json`
- **Issues raised**: none (report task)
