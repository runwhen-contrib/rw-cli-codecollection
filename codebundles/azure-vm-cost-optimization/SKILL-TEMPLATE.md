---
name: azure-vm-cost-optimization
kind: skill-template
description: Azure VM Cost Optimization: Analyzes Virtual Machines to identify cost optimization opportunities including... Use when triaging or monitoring Azure, Cost, Optimization workloads with skill templat...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, Cost, Optimization, Virtual, Machines, VMs, Rightsizing, Deallocation]
resource_types: [virtual_machine]
access: read-only
---

# Azure VM Cost Optimization

## Summary

This codebundle analyzes Azure Virtual Machines to identify cost optimization opportunities.

See [README.md](README.md) for additional context.

## Tools

### Analyze Virtual Machine Rightsizing and Deallocation Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Analyzes Azure Virtual Machines across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) VMs that are stopped but not deallocated (still incurring compute costs), 2) Oversized VMs with low CPU utilization that can be downsized to B-series burstable instances. Examines CPU utilization metrics over the past 30 days to provide data-driven rightsizing recommendations.

- **Robot task name**: <code>Analyze Virtual Machine Rightsizing and Deallocation Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_vm_optimization.sh`
- **Tags**: `Azure`, `Cost`, `Optimization`, `Virtual`, `Machines`, `VMs`, `Rightsizing`, `Deallocation`, `access:read-only`, `data:config`
- **Reads**: `AZURE_SUBSCRIPTION_NAME`, `TIMEOUT_SECONDS`
- **Writes**: `vm_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for VM optimization. | `""` | no |
| `AZURE_RESOURCE_GROUPS` | string | Comma-separated list of resource groups to analyze (leave empty to analyze all resource groups in the subscription) | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name for reporting purposes | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for utilization analysis (default: 30) | `30` | no |
| `LOW_COST_THRESHOLD` | string | Monthly savings threshold for LOW classification (default: 0) | `0` | no |
| `MEDIUM_COST_THRESHOLD` | string | Monthly savings threshold for MEDIUM classification (default: 2000) | `2000` | no |
| `HIGH_COST_THRESHOLD` | string | Monthly savings threshold for HIGH classification (default: 10000) | `10000` | no |
| `AZURE_DISCOUNT_PERCENTAGE` | string | Discount percentage off MSRP for Azure services (default: 0) | `0` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 1500 = 25 minutes). | `1500` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `vm_optimization_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-vm-cost-optimization/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-vm-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export LOW_COST_THRESHOLD=...
export MEDIUM_COST_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-vm-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
bash analyze_vm_optimization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `analyze_vm_optimization.sh` — Bash helper script `analyze_vm_optimization.sh`.
