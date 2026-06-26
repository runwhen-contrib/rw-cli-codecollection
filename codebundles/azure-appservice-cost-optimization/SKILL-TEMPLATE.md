---
name: azure-appservice-cost-optimization
kind: skill-template
description: Azure App Service Cost Optimization: Analyzes App Service Plans to identify empty plans, underutilized resources,... Use when triaging or monitoring Azure, Cost, Optimization workloads with skill t...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, Cost, Optimization, App, Service, Plans, Function, Apps, Web, Apps, Rightsizing]
resource_types: [app_service]
access: read-only
---

# Azure App Service Cost Optimization

## Summary

This codebundle analyzes Azure App Service Plans to identify cost optimization opportunities.

See [README.md](README.md) for additional context.

## Tools

### Analyze App Service Plan Cost Optimization in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Analyzes App Service Plans across subscriptions to identify empty plans, underutilized resources, and rightsizing opportunities with cost savings estimates. Supports three optimization strategies (aggressive/balanced/conservative) and provides comprehensive options tables with risk assessments for each plan.

- **Robot task name**: <code>Analyze App Service Plan Cost Optimization in Resource Group `${AZURE_RESOURCE_GROUPS}` for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `azure_appservice_cost_optimization.sh`
- **Tags**: `Azure`, `Cost`, `Optimization`, `App`, `Service`, `Plans`, `Function`, `Apps`, `Web`, `Apps`, `Rightsizing`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `azure_appservice_cost_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for App Service optimization. | `""` | no |
| `AZURE_RESOURCE_GROUPS` | string | Comma-separated list of resource groups to analyze (leave empty to analyze all resource groups in the subscription) | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name for reporting purposes | `""` | no |
| `LOW_COST_THRESHOLD` | string | Monthly savings threshold for LOW classification (default: 500) | `500` | no |
| `MEDIUM_COST_THRESHOLD` | string | Monthly savings threshold for MEDIUM classification (default: 2000) | `2000` | no |
| `HIGH_COST_THRESHOLD` | string | Monthly savings threshold for HIGH classification (default: 10000) | `10000` | no |
| `OPTIMIZATION_STRATEGY` | string | Optimization strategy: 'aggressive' (max savings, 85-90% target CPU, dev/test), 'balanced' (default, 75-80% target CPU, standard prod), or 'conservative' (safest, 60-70% target CPU, critical prod) | `balanced` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 1500 = 25 minutes). | `1500` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `azure_appservice_cost_optimization_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-appservice-cost-optimization/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-appservice-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export LOW_COST_THRESHOLD=...
export MEDIUM_COST_THRESHOLD=...
export HIGH_COST_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appservice-cost-optimization
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_RESOURCE_GROUPS=...
export AZURE_SUBSCRIPTION_NAME=...
export LOW_COST_THRESHOLD=...
bash azure_appservice_cost_optimization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `azure_appservice_cost_optimization.sh` — Bash helper script `azure_appservice_cost_optimization.sh`.
