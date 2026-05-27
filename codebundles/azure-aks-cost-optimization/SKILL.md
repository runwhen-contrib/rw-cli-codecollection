---
name: azure-aks-cost-optimization
description: Azure AKS Cost Optimization: Analyzes AKS cluster node pools to identify cost optimization opportunities by... Use when triaging or monitoring Azure, Cost, Optimization workloads with skill templat...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, Cost, Optimization, AKS, Kubernetes, Node, Pools, Autoscaling, Capacity, Planning]
resource_types: [aks_cluster]
access: read-only
---

# Azure AKS Cost Optimization

## Summary

This codebundle analyzes Azure Kubernetes Service (AKS) cluster node pools to identify cost optimization opportunities.

See [README.md](README.md) for additional context.

## Tools

### Analyze AKS Node Pool Resizing Opportunities Based on Utilization Metrics in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Analyzes AKS cluster node pools across specified subscriptions, examines both average and peak CPU/memory utilization over the past 30 days, and provides capacity-planned recommendations for reducing minimum node counts or changing VM types to optimize costs. Uses a two-tier approach: minimum nodes based on average utilization (150% safety margin), maximum nodes based on peak utilization (150% safety margin). This ensures cost-effective baseline capacity while maintaining ceiling for traffic spikes. Safety margins are configurable via MIN_NODE_SAFETY_MARGIN_PERCENT and MAX_NODE_SAFETY_MARGIN_PERCENT.

- **Robot task name**: <code>Analyze AKS Node Pool Resizing Opportunities Based on Utilization Metrics in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_aks_node_pool_optimization.sh`
- **Tags**: `Azure`, `Cost`, `Optimization`, `AKS`, `Kubernetes`, `Node`, `Pools`, `Autoscaling`, `Capacity`, `Planning`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `aks_node_pool_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for AKS optimization. | `""` | no |
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

- `aks_node_pool_optimization_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-aks-cost-optimization
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
cd codebundles/azure-aks-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
bash analyze_aks_node_pool_optimization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `analyze_aks_node_pool_optimization.sh` — Bash helper script `analyze_aks_node_pool_optimization.sh`.
