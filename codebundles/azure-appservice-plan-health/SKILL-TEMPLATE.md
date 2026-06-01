---
name: azure-appservice-plan-health
kind: skill-template
description: Check Azure App Service Plan health by identifying availability issues, high usage issues, and providing scaling... Use when triaging or monitoring Azure, App, Service workloads with skill template...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, App, Service, Plan, Health]
resource_types: [app_service]
access: read-only
---

# Azure    App Service Plan Health

## Summary

This codebundle runs a suite of metrics checks for App Service Plan health in Azure.

See [README.md](README.md) for additional context.

## Tools

### Check Azure App Service Plan Resource Health in resource group `${AZURE_RESOURCE_GROUP}`

Check the Azure Resource Health API for any known issues affecting App Service Plans

- **Robot task name**: <code>Check Azure App Service Plan Resource Health in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `asp-health-check.sh`
- **Tags**: `AppServicePlan`, `Azure`, `Health`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_NAME`
- **Writes**: `asp_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check App Service Plan Capacity and Recommendations in resource group `${AZURE_RESOURCE_GROUP}`

Check App Service Plan capacity, report high usage issues, and provide scaling recommendations

- **Robot task name**: <code>Check App Service Plan Capacity and Recommendations in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_appservice_plan_capacity.sh`
- **Tags**: `AppService`, `Azure`, `Capacity`, `Recommendations`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_NAME`
- **Writes**: `asp_high_usage_metrics.json`, `asp_recommendations.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze App Service Plan Cost Optimization Opportunities in resource group `${AZURE_RESOURCE_GROUP}`

Analyzes 30-day utilization trends using Azure Monitor to identify underutilized App Service Plans with cost savings opportunities. Provides Azure pricing-based estimates for potential monthly and annual savings with severity bands: Sev4 <$2k/month, Sev3 $2k-$10k/month, Sev2 >$10k/month.

- **Robot task name**: <code>Analyze App Service Plan Cost Optimization Opportunities in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `asp_cost_optimization.sh`
- **Tags**: `AppServicePlan`, `cost-optimization`, `underutilization`, `azure-monitor`, `pricing`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `asp_cost_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze App Service Plan Weekly Utilization Trends in resource group `${AZURE_RESOURCE_GROUP}`

Analyzes week-over-week utilization trends for App Service Plans including CPU, memory, request counts, HTTP error rates, and response times. Detects growth patterns that may indicate scaling needs or performance issues.

- **Robot task name**: <code>Analyze App Service Plan Weekly Utilization Trends in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `asp_weekly_trend_analysis.sh`
- **Tags**: `AppServicePlan`, `Azure`, `Trends`, `Utilization`, `Performance`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `asp_weekly_trend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check App Service Plan Changes in resource group `${AZURE_RESOURCE_GROUP}`

Lists App Service Plan changes and operations from Azure Activity Log

- **Robot task name**: <code>Check App Service Plan Changes in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `asp-audit.sh`
- **Tags**: `AppServicePlan`, `Azure`, `Audit`, `Security`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Check Azure App Service Plan health by identifying availability issues, high capacity usage

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Count App Service Plans with Health Status of `Available` in resource group `${AZURE_RESOURCE_GROUP}`

Count Azure App Service Plans with health status of `Available`

- **Robot task name**: <code>Count App Service Plans with Health Status of `Available` in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `availability`
- **Underlying script**: `asp-health-check.sh`
- **Tags**: `AppServicePlan`, `Azure`, `Health`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `int(${count}) >= 1`


#### Count App Service Plans with High Capacity Usage in resource group `${AZURE_RESOURCE_GROUP}`

Count App Service Plans with high CPU, memory, or disk queue usage

- **Robot task name**: <code>Count App Service Plans with High Capacity Usage in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `capacity_usage`
- **Underlying script**: `check_appservice_plan_capacity.sh`
- **Tags**: `AppService`, `Azure`, `Health`, `access:read-only`, `data:config`
- **Reads**: `MAX_HIGH_USAGE_APP_SERVICE_PLAN`
- **Pass condition**: `int(${count}) <= int(${MAX_HIGH_USAGE_APP_SERVICE_PLAN})`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_RESOURCE_GROUP` | string | Azure resource group. | — | yes |
| `AZURE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name. | `""` | no |
| `AZURE_ACTIVITY_LOG_OFFSET` | string | Time offset for activity log collection (e.g., 24h, 7d) (default: 24h) | `24h` | no |
| `CPU_THRESHOLD` | string | CPU usage threshold percentage for high usage alerts (default: 80) | `80` | no |
| `MEMORY_THRESHOLD` | string | Memory usage threshold percentage for high usage alerts (default: 80) | `80` | no |
| `DISK_QUEUE_THRESHOLD` | string | Disk queue length threshold for high usage alerts (default: 10) | `10` | no |
| `SCALE_UP_CPU_THRESHOLD` | string | CPU usage threshold percentage for scale up recommendations (default: 70) | `70` | no |
| `SCALE_UP_MEMORY_THRESHOLD` | string | Memory usage threshold percentage for scale up recommendations (default: 70) | `70` | no |
| `SCALE_DOWN_CPU_THRESHOLD` | string | CPU usage threshold percentage for scale down recommendations (default: 30) | `30` | no |
| `SCALE_DOWN_MEMORY_THRESHOLD` | string | Memory usage threshold percentage for scale down recommendations (default: 30) | `30` | no |
| `METRICS_OFFSET` | string | Time offset for metrics collection (e.g., 24h, 7d) (default: 24h) | `24h` | no |
| `METRICS_INTERVAL` | string | Metrics collection interval (e.g., PT1H, PT5M) (default: PT1H) | `PT1H` | no |
| `LOOKBACK_WEEKS` | string | Number of weeks to analyze for trend analysis (default: 4) | `4` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 900). | `900` | no |
| `MAX_UNUSED_DISK` | string | The maximum number of unused disks allowed in the subscription. | `0` | no |
| `MAX_UNUSED_SNAPSHOT` | string | The maximum number of unused snapshots allowed in the subscription. | `0` | no |
| `UNUSED_STORAGE_ACCOUNT_TIMEFRAME` | string | The timeframe in hours to check for unused storage accounts (e.g., 720 for 30 days) | `24` | no |
| `MAX_UNUSED_STORAGE_ACCOUNT` | string | The maximum number of unused storage accounts allowed in the subscription. | `0` | no |
| `MAX_PUBLIC_ACCESS_STORAGE_ACCOUNT` | string | The maximum number of storage accounts with public access allowed in the subscription. | `0` | no |
| `MAX_HIGH_USAGE_APP_SERVICE_PLAN` | string | The maximum number of high usage App Service Plans allowed in the subscription. | `0` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `asp_health.json`
- `asp_high_usage_metrics.json`
- `asp_recommendations.json`
- `asp_cost_optimization_issues.json`
- `asp_weekly_trend_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-appservice-plan-health
export AZURE_RESOURCE_GROUP=...
export AZURE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
export AZURE_ACTIVITY_LOG_OFFSET=...
export CPU_THRESHOLD=...
export MEMORY_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appservice-plan-health
export AZURE_RESOURCE_GROUP=...
export AZURE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
export AZURE_ACTIVITY_LOG_OFFSET=...
bash asp-audit.sh
bash asp-health-check.sh
bash asp_cost_optimization.sh
bash asp_weekly_trend_analysis.sh
bash check_appservice_plan_capacity.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `asp-audit.sh` — Bash helper script `asp-audit.sh`.
- `asp-health-check.sh` — Bash helper script `asp-health-check.sh`.
- `asp_cost_optimization.sh` — Bash helper script `asp_cost_optimization.sh`.
- `asp_weekly_trend_analysis.sh` — Bash helper script `asp_weekly_trend_analysis.sh`.
- `check_appservice_plan_capacity.sh` — Bash helper script `check_appservice_plan_capacity.sh`.
