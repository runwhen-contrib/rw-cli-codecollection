---
name: gcp-project-cost-health
description: GCP cost management toolkit: generate historical cost reports by service/project using BigQuery billing export.... Use when triaging or monitoring GCP, Cost, Optimization workloads with skill templ...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [GCP, Cost, Optimization, Cost, Management, Cost, Reporting, BigQuery, Trend, Analysis]
resource_types: [gcp_resource]
access: read-only
---

# GCP Project Cost Health & Reporting

## Summary

Comprehensive toolkit for analyzing GCP costs and spending across projects using BigQuery billing export.

See [README.md](README.md) for additional context.

## Tools

### Generate GCP Cost Report By Service and Project

Generates a detailed cost breakdown report showing actual spending by project and GCP service using BigQuery billing export. Includes month-over-month comparison across the last 3 complete calendar months with per-project and per-service trend analysis. Raises issues when cost increases exceed the configured threshold.

- **Robot task name**: <code>Generate GCP Cost Report By Service and Project</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `display_top_projects.sh`
- **Tags**: `GCP`, `Cost`, `Analysis`, `Cost`, `Management`, `Reporting`, `Trend`, `Analysis`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `gcp_cost_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze GCP Network Costs By SKU

Analyzes network-related costs broken down by SKU, showing daily spend for the last 7 days, weekly, monthly, and three-month spend. Detects cost anomalies, deviations, and projects future costs based on recent spending trends to provide early warnings.

- **Robot task name**: <code>Analyze GCP Network Costs By SKU</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `gcp_network_cost_analysis.sh`
- **Tags**: `GCP`, `Network`, `Cost`, `Analysis`, `Egress`, `Ingress`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `gcp_network_cost_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get GCP Cost Optimization Recommendations

Fetches COST-RELATED recommendations from GCP Recommender API (committed use discounts, idle resources, rightsizing, etc.). Filters out non-cost recommendations like security/IAM suggestions.

- **Robot task name**: <code>Get GCP Cost Optimization Recommendations</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `gcp_recommendations.sh`
- **Tags**: `GCP`, `Cost`, `Optimization`, `Recommendations`, `FinOps`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `gcp_recommendations_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_IDS` | string | Comma-separated list of GCP project IDs to analyze for cost optimization (e.g., "project-1,project-2,project-3"). If left blank, will assess all projects found in the billing export. | `""` | no |
| `GCP_BILLING_EXPORT_TABLE` | string | BigQuery table path for billing export in format: project-id.dataset_name.gcp_billing_export_v1_XXXXXX (optional - will auto-discover if not provided) | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for cost analysis (default: 30) | `30` | no |
| `GCP_COST_BUDGET` | string | Optional budget threshold in USD. A severity 3 issue will be raised if total costs exceed this amount. Leave at 0 to disable. | `10000` | no |
| `GCP_PROJECT_COST_THRESHOLD_PERCENT` | string | Optional percentage threshold (0-100). A severity 3 issue will be raised if any single project exceeds this percentage of total costs. Leave at 0 to disable. | `25` | no |
| `NETWORK_COST_THRESHOLD_MONTHLY` | string | Monthly network cost threshold (in USD) for severity 3 alerts. Triggers on SKUs that exceed this amount OR are projected to breach it based on recent spending trends (last 7 days). | `200` | no |
| `COST_INCREASE_THRESHOLD` | string | Percentage threshold for month-over-month cost increase alerts. An issue will be raised if total, per-project, or per-service costs increase by more than this percentage between calendar months (default: 10 for 10%). | `10` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- `gcp_cost_issues.json`
- `gcp_network_cost_issues.json`
- `gcp_recommendations_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/gcp-project-cost-health
export GCP_PROJECT_IDS=...
export GCP_BILLING_EXPORT_TABLE=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export GCP_COST_BUDGET=...
export GCP_PROJECT_COST_THRESHOLD_PERCENT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-project-cost-health
export GCP_PROJECT_IDS=...
export GCP_BILLING_EXPORT_TABLE=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
bash display_top_projects.sh
bash gcp_cost_historical_report.sh
bash gcp_network_cost_analysis.sh
bash gcp_recommendations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `display_top_projects.sh` — Bash helper script `display_top_projects.sh`.
- `gcp_cost_historical_report.sh` — Bash helper script `gcp_cost_historical_report.sh`.
- `gcp_network_cost_analysis.sh` — Bash helper script `gcp_network_cost_analysis.sh`.
- `gcp_recommendations.sh` — Bash helper script `gcp_recommendations.sh`.
