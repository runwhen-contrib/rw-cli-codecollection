---
name: aws-account-cost-health
kind: skill-template
description: AWS Account Cost Report: Generates historical cost breakdown reports by service using the AWS Cost Explorer API.... Use when triaging or monitoring AWS, Cost, Management workloads with skill templa...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [AWS, Cost, Management, Cost, Reporting, Trend, Analysis, Reserved, Instances, Savings, Plans]
resource_types: [aws_resource]
access: read-only
---

# AWS Account Cost Report

## Summary

This codebundle monitors AWS account cost trends using the Cost Explorer API and provides Reserved Instance and Savings Plans purchase recommendations.

See [README.md](README.md) for additional context.

## Tools

### Generate AWS Cost Report By Service for Account `${AWS_ACCOUNT_NAME}`

Generates a detailed cost breakdown report for the configured lookback period showing actual spending by AWS service. Includes period-over-period comparison and raises an issue if cost increase exceeds configured threshold.

- **Robot task name**: <code>Generate AWS Cost Report By Service for Account `${AWS_ACCOUNT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aws_cost_report.sh`
- **Tags**: `AWS`, `Cost`, `Analysis`, `Cost`, `Management`, `Reporting`, `Trend`, `Analysis`, `access:read-only`, `data:config`
- **Reads**: `AWS_ACCOUNT_NAME`, `TIMEOUT_SECONDS`
- **Writes**: `aws_cost_trend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze AWS Reserved Instance and Savings Plans Recommendations for Account `${AWS_ACCOUNT_NAME}`

Queries AWS Cost Explorer for Reserved Instance and Savings Plans purchase recommendations. Calculates potential savings from commitments for EC2, RDS, ElastiCache, and Compute Savings Plans.

- **Robot task name**: <code>Analyze AWS Reserved Instance and Savings Plans Recommendations for Account `${AWS_ACCOUNT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aws_ri_recommendations.sh`
- **Tags**: `AWS`, `Cost`, `Analysis`, `Reserved`, `Instances`, `Savings`, `Plans`, `access:read-only`, `data:config`
- **Reads**: `AWS_ACCOUNT_NAME`, `TIMEOUT_SECONDS`
- **Writes**: `aws_ri_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AWS_REGION` | string | AWS Region for Cost Explorer API calls | `us-east-1` | no |
| `AWS_ACCOUNT_NAME` | string | AWS account name or alias for display purposes | `""` | no |
| `COST_ANALYSIS_LOOKBACK_DAYS` | string | Number of days to look back for cost analysis (default: 30) | `30` | no |
| `COST_INCREASE_THRESHOLD` | string | Percentage threshold for cost increase alerts. An issue will be raised if period-over-period cost increase exceeds this value (e.g., 10 for 10% increase). | `10` | no |
| `OUTPUT_FORMAT` | string | Output format for cost report: table, csv, json, or all (default: table) | `table` | no |
| `COST_BUDGET` | string | Budget threshold in USD for the analysis period. An issue will be raised if total costs exceed this value. Set to 0 to disable (default: 0). | `0` | no |
| `COST_CONCENTRATION_THRESHOLD` | string | Maximum percentage of total cost that any single service should represent. An issue will be raised if exceeded (default: 25). | `25` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 600 = 10 minutes). | `600` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `aws_cost_trend_issues.json`
- `aws_ri_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/aws-account-cost-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export COST_INCREASE_THRESHOLD=...
export OUTPUT_FORMAT=...
export COST_BUDGET=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/aws-account-cost-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
export COST_ANALYSIS_LOOKBACK_DAYS=...
export COST_INCREASE_THRESHOLD=...
bash aws_cost_report.sh
bash aws_ri_recommendations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `aws_cost_report.sh` — Bash helper script `aws_cost_report.sh`.
- `aws_ri_recommendations.sh` — Bash helper script `aws_ri_recommendations.sh`.
