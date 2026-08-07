---
name: gcp-compute-vm-health
kind: skill-template
description: Monitor the health of standalone GCP Compute Engine VMs (uptime, OS patches, disk utilization, network health, and guest/serial console). Use when triaging or monitoring GCP, Compute VMs with skill template `gcp-compute-vm-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Compute, VM, Health, Uptime, Disk]
resource_types: [gcp_resource]
access: read-only
---

# GCP Compute Engine VM Health

## Summary

Monitors standalone GCP Compute Engine VMs (instances NOT part of an instance
group) for long uptime without a reboot, missing/pending OS patches, filling or
degraded disks, unhealthy networking, and guest/serial console issues, then
produces a consolidated per-VM health summary.

See [README.md](README.md) for additional context.

## Tools

### Discover Standalone GCP Compute VMs in Project `${GCP_PROJECT_ID}`

Lists standalone VM instances in the project (excluding instance-group
members) and dumps VM configuration (name, zone, status, machine type).

- **Robot task name**: <code>Discover Standalone GCP Compute VMs in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `discover_vms.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `discovered_vms.json`
- **Issues raised**: severity 3 when no standalone VMs are found

### Check VM Uptime and Operational Status for `${VM_NAME}`

Checks instance status and uptime, flagging VMs running longer than
`UPTIME_WARNING_DAYS` or in a degraded/non-running state.

- **Robot task name**: <code>Check VM Uptime and Operational Status for `${VM_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_uptime.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `uptime`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `VM_NAME`, `UPTIME_WARNING_DAYS`
- **Writes**: `uptime_issues.json`
- **Issues raised**: severity 2 (overdue reboot) / severity 3 (not RUNNING)

### Check VM OS Patch Status via OS Config for `${VM_NAME}`

Inspects OS Config vulnerability reports and OS policy compliance.

- **Robot task name**: <code>Check VM OS Patch Status via OS Config for `${VM_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_patch_status.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `osconfig`, `patch`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`, `VM_NAME`, `PATCH_WARNING_DAYS`
- **Writes**: `patch_issues.json`
- **Issues raised**: severity 2 (affected vulnerabilities) / severity 3 (OS policy violation)

### Check VM Disk Utilization for `${VM_NAME}`

Checks boot/attached disk utilization and disk state.

- **Robot task name**: <code>Check VM Disk Utilization for `${VM_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_disk_utilization.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `disk`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `VM_NAME`, `DISK_USAGE_THRESHOLD`
- **Writes**: `disk_issues.json`
- **Issues raised**: severity 3 (degraded disk) / severity 4 (disk filling)

### Check VM Network Health for `${VM_NAME}`

Verifies internal/external IP assignment, network tag/firewall consistency, and
packet-loss indicators.

- **Robot task name**: <code>Check VM Network Health for `${VM_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_network_health.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `network`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `VM_NAME`
- **Writes**: `network_issues.json`
- **Issues raised**: severity 3 (no interface / tag-firewall mismatch / packet loss)

### Check VM Guest and Serial Console Health for `${VM_NAME}`

Scans serial console output and metadata for guest agent, boot, and console
errors.

- **Robot task name**: <code>Check VM Guest and Serial Console Health for `${VM_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_console_health.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `console`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`, `VM_NAME`
- **Writes**: `console_issues.json`
- **Issues raised**: severity 2–3 based on serial console error pattern

### Generate VM Health Summary for `${GCP_PROJECT_ID}`

Aggregates per-VM findings into a consolidated health summary with an overall
verdict.

- **Robot task name**: <code>Generate VM Health Summary for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_vm_summary.sh`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `vm_health_summary.json`, `summary_issues.json`
- **Issues raised**: severity 3 per non-RUNNING VM

## Monitor

Health score in the range **0 (degraded) – 1 (healthy)** computed as the
arithmetic mean of five binary dimensions.

- **Robot file**: `sli.robot`
- **Score range**: `0` to `1`
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score VM Operational Status and Uptime for `${VM_NAME}`

Scores 1 if the VM is RUNNING and has not exceeded `UPTIME_WARNING_DAYS`.

- **Robot task name**: <code>Score VM Operational Status and Uptime for `${VM_NAME}`</code>
- **Sub-metric names**: `uptime_status`, `uptime_issue_count`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `uptime`, `access:read-only`, `data:metrics`
- **Pass condition**: `uptime_issue_count == 0`

#### Score VM OS Patch Status for `${VM_NAME}`

Scores 1 if no affected/missing patches or OS policy violations.

- **Robot task name**: <code>Score VM OS Patch Status for `${VM_NAME}`</code>
- **Sub-metric names**: `patch_status`, `patch_issue_count`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `osconfig`, `patch`, `access:read-only`, `data:logs-config`
- **Pass condition**: `patch_issue_count == 0`

#### Score VM Disk Utilization for `${VM_NAME}`

Scores 1 if no disk exceeds `DISK_USAGE_THRESHOLD` percent or is degraded.

- **Robot task name**: <code>Score VM Disk Utilization for `${VM_NAME}`</code>
- **Sub-metric names**: `disk_status`, `disk_issue_count`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `disk`, `access:read-only`, `data:metrics`
- **Pass condition**: `disk_issue_count == 0`

#### Score VM Network Health for `${VM_NAME}`

Scores 1 if no network health issues.

- **Robot task name**: <code>Score VM Network Health for `${VM_NAME}`</code>
- **Sub-metric names**: `network_status`, `network_issue_count`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `network`, `access:read-only`, `data:metrics`
- **Pass condition**: `network_issue_count == 0`

#### Score VM Guest and Serial Console Health for `${VM_NAME}`

Scores 1 if no guest agent, boot, or serial console errors.

- **Robot task name**: <code>Score VM Guest and Serial Console Health for `${VM_NAME}`</code>
- **Sub-metric names**: `console_status`, `console_issue_count`
- **Tags**: `gcloud`, `compute`, `vm`, `gcp`, `console`, `access:read-only`, `data:logs-config`
- **Pass condition**: `console_issue_count == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP project ID hosting the VMs. | — | yes |
| `VM_NAME` | string | Standalone VM to check, or `All` to scan every standalone VM. | `All` | no |
| `UPTIME_WARNING_DAYS` | string | Days a VM may run before a reboot is encouraged. | `90` | no |
| `PATCH_WARNING_DAYS` | string | Days a missing/pending patch may go unremediated before alerting. | `30` | no |
| `DISK_USAGE_THRESHOLD` | string | Disk usage percentage above which a disk is flagged. | `85` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON used to authenticate with GCP APIs. | yes |

## Outputs

- 0–1 monitor health score pushed by `sli.robot`, plus per-dimension sub-metrics
- `discovered_vms.json`
- `uptime_issues.json`
- `patch_issues.json`
- `disk_issues.json`
- `network_issues.json`
- `console_issues.json`
- `vm_health_summary.json`, `summary_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-compute-vm-health/runbook.robot`
- **Monitor**: `codebundles/gcp-compute-vm-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-compute-vm-health
export GCP_PROJECT_ID=...
export VM_NAME=All
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-compute-vm-health
export GCP_PROJECT_ID=...
export VM_NAME=All
bash discover_vms.sh
bash check_uptime.sh
bash check_patch_status.sh
bash check_disk_utilization.sh
bash check_network_health.sh
bash check_console_health.sh
bash generate_vm_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — 0–1 multi-dimensional monitor scoring
- `gcp_vm_common.sh` — shared helpers (issue building, standalone VM discovery, uptime)
- `discover_vms.sh` — lists standalone compute VMs
- `check_uptime.sh` — uptime and operational status
- `check_patch_status.sh` — OS Config patch/vulnerability compliance
- `check_disk_utilization.sh` — disk utilization and state
- `check_network_health.sh` — network health
- `check_console_health.sh` — guest/serial console health
- `generate_vm_summary.sh` — consolidated health summary
