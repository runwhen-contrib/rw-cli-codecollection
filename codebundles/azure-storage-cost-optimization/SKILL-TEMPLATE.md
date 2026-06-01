---
name: azure-storage-cost-optimization
kind: skill-template
description: Azure Storage Cost Optimization: Analyzes storage resources to identify cost optimization opportunities including... Use when triaging or monitoring Azure, Cost, Optimization workloads with skill t...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, Cost, Optimization, Storage, Managed, Disks, Snapshots, Blob, Storage, Lifecycle, Management]
resource_types: [storage_account]
access: read-only
---

# Azure Storage Cost Optimization

## Summary

This codebundle analyzes Azure storage resources to identify cost optimization opportunities.

See [README.md](README.md) for additional context.

## Tools

### Analyze Azure Storage Cost Optimization Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Analyzes Azure storage resources across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Unattached/orphaned managed disks still incurring costs, 2) Old snapshots (>90 days by default) consuming storage, 3) Storage accounts without lifecycle management policies, 4) Over-provisioned redundancy (GRS/GZRS that could use LRS/ZRS), 5) Premium disks with low IOPS utilization that could be downgraded to Standard SSD.

- **Robot task name**: <code>Analyze Azure Storage Cost Optimization Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_storage_optimization.sh`
- **Tags**: `Azure`, `Cost`, `Optimization`, `Storage`, `Managed`, `Disks`, `Snapshots`, `Blob`, `Storage`, `Lifecycle`, `Management`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `storage_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for storage optimization. | `""` | no |
| `AZURE_RESOURCE_GROUPS` | string | Comma-separated list of resource groups to analyze (leave empty to analyze all resource groups in the subscription) | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name for reporting purposes | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for utilization analysis (default: 30) | `30` | no |
| `LOW_COST_THRESHOLD` | string | Monthly savings threshold for LOW classification (default: 500) | `500` | no |
| `MEDIUM_COST_THRESHOLD` | string | Monthly savings threshold for MEDIUM classification (default: 2000) | `2000` | no |
| `HIGH_COST_THRESHOLD` | string | Monthly savings threshold for HIGH classification (default: 10000) | `10000` | no |
| `AZURE_DISCOUNT_PERCENTAGE` | string | Discount percentage off MSRP for Azure services (default: 0) | `0` | no |
| `SNAPSHOT_AGE_THRESHOLD_DAYS` | string | Age threshold in days for identifying old snapshots that may be candidates for deletion (default: 90) | `90` | no |
| `SCAN_MODE` | string | Performance mode: 'full' (detailed, actual metrics), 'quick' (fast, estimates usage), 'sample' (analyze subset and extrapolate). Default: full | `full` | no |
| `MAX_PARALLEL_JOBS` | string | Maximum parallel jobs for metrics collection in full mode (default: 10) | `10` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 1500 = 25 minutes). | `1500` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `storage_optimization_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-storage-cost-optimization
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
cd codebundles/azure-storage-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
bash analyze_storage_optimization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `analyze_storage_optimization.sh` — Bash helper script `analyze_storage_optimization.sh`.
