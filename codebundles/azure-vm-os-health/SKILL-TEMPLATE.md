---
name: azure-vm-os-health
kind: skill-template
description: Runs diagnostic checks against Azure VMs to monitor disk utilization, memory utilization, uptime, patch status and... Use when triaging or monitoring Azure, Virtual, Machine workloads with skill te...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, Virtual, Machine, Disk, Health, Uptime]
resource_types: [virtual_machine]
access: read-only
---

# Azure VM Health Check

## Summary

This bundle provides comprehensive health checks for Azure Virtual Machines, including disk utilization, memory usage, uptime, and patch status.

See [README.md](README.md) for additional context.

## Tools

### Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks disk utilization for VMs and parses each result.

- **Robot task name**: <code>Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `next_steps_disk_utilization.sh`
- **Tags**: `access:read-only`, `VM`, `Azure`, `Disk`, `Health`, `data:config`
- **Reads**: `AZURE_SUBSCRIPTION_NAME`, `AZ_RESOURCE_GROUP`, `DISK_THRESHOLD`, `MAX_PARALLEL_JOBS`, `TIMEOUT_SECONDS`, `VM_INCLUDE_LIST`, `VM_OMIT_LIST`
- **Writes**: `disk_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks memory utilization for VMs and parses each result.

- **Robot task name**: <code>Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `next_steps_memory_check.sh`
- **Tags**: `access:read-only`, `VM`, `Azure`, `Memory`, `Health`, `data:config`
- **Reads**: `AZURE_SUBSCRIPTION_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `memory_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks uptime for VMs and parses each result.

- **Robot task name**: <code>Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `next_steps_uptime.sh`
- **Tags**: `access:read-only`, `VM`, `Azure`, `Uptime`, `Health`, `data:config`
- **Reads**: `AZURE_SUBSCRIPTION_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `uptime_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks last patch status for VMs and parses each result.

- **Robot task name**: <code>Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `next_steps_patch_time.sh`
- **Tags**: `access:read-only`, `VM`, `Azure`, `Patch`, `Health`, `data:config`
- **Reads**: `AZURE_SUBSCRIPTION_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `patch_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Calculates Azure VM health by checking disk, memory, uptime, and patch status.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks disk utilization for VMs and parses each result.

- **Robot task name**: <code>Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `disk_utilization`
- **Underlying script**: `next_steps_disk_utilization.sh`
- **Tags**: `VM`, `Azure`, `Disk`, `Health`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks memory utilization for VMs and parses each result.

- **Robot task name**: <code>Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `memory_utilization`
- **Underlying script**: `next_steps_memory_check.sh`
- **Tags**: `VM`, `Azure`, `Memory`, `Health`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks uptime for VMs and parses each result.

- **Robot task name**: <code>Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `vm_uptime`
- **Underlying script**: `next_steps_uptime.sh`
- **Tags**: `VM`, `Azure`, `Uptime`, `Health`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`

Checks last patch status for VMs and parses each result.

- **Robot task name**: <code>Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `patch_status`
- **Underlying script**: `next_steps_patch_time.sh`
- **Tags**: `VM`, `Azure`, `Patch`, `Health`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group containing the VM(s). | — | yes |
| `DISK_THRESHOLD` | string | The threshold percentage for disk usage warnings. | `85` | no |
| `UPTIME_THRESHOLD` | string | The threshold in days for system uptime warnings. | `30` | no |
| `MEMORY_THRESHOLD` | string | The threshold percentage for memory usage warnings. | `90` | no |
| `MAX_PARALLEL_JOBS` | string | Maximum number of parallel VM checks to run simultaneously. | `5` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for Azure VM run-command operations. | `90` | no |
| `VM_INCLUDE_LIST` | string | Comma-separated list of VM name patterns to include (e.g., "web-*,app-*"). If empty, all VMs are processed. | — | yes |
| `VM_OMIT_LIST` | string | Comma-separated list of VM name patterns to exclude (e.g., "test-*,dev-*"). If empty, no VMs are excluded. | — | yes |
| `AZURE_SUBSCRIPTION_ID` | string | The Azure Subscription ID. | — | yes |
| `AZURE_SUBSCRIPTION_NAME` | string | The Azure Subscription Name. | `subscription-01` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `disk_utilization_issues.json`
- `memory_utilization_issues.json`
- `uptime_issues.json`
- `patch_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-vm-os-health
export AZ_RESOURCE_GROUP=...
export DISK_THRESHOLD=...
export UPTIME_THRESHOLD=...
export MEMORY_THRESHOLD=...
export MAX_PARALLEL_JOBS=...
export TIMEOUT_SECONDS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-vm-os-health
export AZ_RESOURCE_GROUP=...
export DISK_THRESHOLD=...
export UPTIME_THRESHOLD=...
export MEMORY_THRESHOLD=...
bash next_steps_disk_utilization.sh
bash next_steps_memory_check.sh
bash next_steps_patch_time.sh
bash next_steps_uptime.sh
bash vm_disk_utilization.sh
bash vm_last_patch_check.sh
bash vm_memory_check.sh
bash vm_uptime_check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `next_steps_disk_utilization.sh` — Bash helper script `next_steps_disk_utilization.sh`.
- `next_steps_memory_check.sh` — Bash helper script `next_steps_memory_check.sh`.
- `next_steps_patch_time.sh` — Bash helper script `next_steps_patch_time.sh`.
- `next_steps_uptime.sh` — Bash helper script `next_steps_uptime.sh`.
- `vm_disk_utilization.sh` — Bash helper script `vm_disk_utilization.sh`.
- `vm_last_patch_check.sh` — Bash helper script `vm_last_patch_check.sh`.
- `vm_memory_check.sh` — Bash helper script `vm_memory_check.sh`.
- `vm_uptime_check.sh` — Bash helper script `vm_uptime_check.sh`.
