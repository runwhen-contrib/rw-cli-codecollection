---
name: azure-databricks-cost-optimization
kind: skill-template
description: Azure Databricks Cost Optimization: Analyzes Databricks workspaces and clusters to identify cost optimization... Use when triaging or monitoring Azure, Cost, Optimization workloads with skill templ...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, Cost, Optimization, Databricks, Spark, Clusters, Auto-Termination]
resource_types: [databricks_workspace]
access: read-only
---

# Azure Databricks Cost Optimization

## Summary

This codebundle analyzes Azure Databricks workspaces and clusters to identify cost optimization opportunities.

See [README.md](README.md) for additional context.

## Tools

### Analyze Databricks Cluster Auto-Termination and Over-Provisioning Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Analyzes Azure Databricks workspaces and clusters across specified subscriptions to identify cost optimization opportunities. Focuses on: 1) Clusters without auto-termination configured or running idle, 2) Over-provisioned clusters with low CPU/memory utilization. Calculates both VM costs and DBU (Databricks Unit) costs to provide accurate savings estimates.

- **Robot task name**: <code>Analyze Databricks Cluster Auto-Termination and Over-Provisioning Opportunities in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_databricks_cluster_optimization.sh`
- **Tags**: `Azure`, `Cost`, `Optimization`, `Databricks`, `Spark`, `Clusters`, `Auto-Termination`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `databricks_cluster_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for Databricks optimization. | `""` | no |
| `AZURE_RESOURCE_GROUPS` | string | Comma-separated list of resource groups to analyze (leave empty to analyze all resource groups in the subscription) | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name for reporting purposes | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for utilization analysis (default: 30) | `30` | no |
| `LOW_COST_THRESHOLD` | string | Monthly savings threshold for LOW classification (default: 500) | `500` | no |
| `MEDIUM_COST_THRESHOLD` | string | Monthly savings threshold for MEDIUM classification (default: 2000) | `2000` | no |
| `HIGH_COST_THRESHOLD` | string | Monthly savings threshold for HIGH classification (default: 10000) | `10000` | no |
| `AZURE_DISCOUNT_PERCENTAGE` | string | Discount percentage off MSRP for Azure services (default: 0) | `0` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 1500 = 25 minutes). | `1500` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `databricks_cluster_optimization_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-databricks-cost-optimization
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
cd codebundles/azure-databricks-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
bash analyze_databricks_cluster_optimization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `analyze_databricks_cluster_optimization.sh` — Bash helper script `analyze_databricks_cluster_optimization.sh`.
