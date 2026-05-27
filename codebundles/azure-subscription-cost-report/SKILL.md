---
name: azure-subscription-cost-report
description: Azure Cost Report: Generates historical cost breakdown reports by service and resource group using the Cost... Use when triaging or monitoring Azure, Cost, Management workloads with skill template ...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, Cost, Management, Cost, Reporting, Trend, Analysis, Reserved, Instances]
resource_types: [subscription]
access: read-only
---

# Azure Subscription Cost Report

## Summary

This codebundle generates detailed cost breakdown reports for Azure subscriptions using the Cost Management API, and provides Reserved Instance purchase recommendations from Azure Advisor.

See [README.md](README.md) for additional context.

## Tools

### Generate Azure Cost Report By Service and Resource Group for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Generates a detailed cost breakdown report for the last 30 days showing actual spending by resource group and Azure service using the Cost Management API. Includes period-over-period comparison and raises an issue if cost increase exceeds configured threshold.

- **Robot task name**: <code>Generate Azure Cost Report By Service and Resource Group for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `azure_cost_historical_report.sh`
- **Tags**: `Azure`, `Cost`, `Analysis`, `Cost`, `Management`, `Reporting`, `Trend`, `Analysis`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `azure_cost_trend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Azure Advisor Reserved Instance Recommendations for Subscription `${AZURE_SUBSCRIPTION_NAME}`

Queries Azure Advisor and the Reservations API to identify Reserved Instance purchase opportunities. Calculates potential savings from 1-year and 3-year commitments for VMs, App Service Plans, and other eligible resources.

- **Robot task name**: <code>Analyze Azure Advisor Reserved Instance Recommendations for Subscription `${AZURE_SUBSCRIPTION_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `azure_advisor_reservation_recommendations.sh`
- **Tags**: `Azure`, `Cost`, `Analysis`, `Reserved`, `Instances`, `Advisor`, `Savings`, `access:read-only`, `data:config`
- **Reads**: `TIMEOUT_SECONDS`
- **Writes**: `azure_advisor_ri_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_SUBSCRIPTION_IDS` | string | Comma-separated list of Azure subscription IDs to analyze for cost reporting (e.g., "sub1,sub2,sub3"). Leave empty to use current subscription. | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | Azure subscription name for reporting purposes | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for cost analysis (default: 30) | `30` | no |
| `COST_INCREASE_THRESHOLD` | string | Percentage threshold for cost increase alerts. An issue will be raised if period-over-period cost increase exceeds this value (e.g., 10 for 10% increase, default: 10) | `10` | no |
| `COST_BUDGET` | string | Budget threshold in USD for the analysis period. An issue will be raised if total costs exceed this value. Set to 0 to disable (default: 0). | `0` | no |
| `COST_CONCENTRATION_THRESHOLD` | string | Maximum percentage of total cost that any single resource group should represent. An issue will be raised if any resource group exceeds this threshold (default: 25). | `25` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 1500 = 25 minutes). | `1500` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `azure_cost_trend_issues.json`
- `azure_advisor_ri_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-subscription-cost-report
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export COST_INCREASE_THRESHOLD=...
export COST_BUDGET=...
export COST_CONCENTRATION_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-subscription-cost-report
export AZURE_SUBSCRIPTION_IDS=...
export AZURE_SUBSCRIPTION_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export COST_INCREASE_THRESHOLD=...
bash azure_advisor_reservation_recommendations.sh
bash azure_cost_historical_report.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `azure_advisor_reservation_recommendations.sh` — Bash helper script `azure_advisor_reservation_recommendations.sh`.
- `azure_cost_historical_report.sh` — Bash helper script `azure_cost_historical_report.sh`.
