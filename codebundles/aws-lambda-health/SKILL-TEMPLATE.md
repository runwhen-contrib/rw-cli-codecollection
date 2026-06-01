---
name: aws-lambda-health
kind: skill-template
description: Scans for AWS Lambda invocation errors. Use when triaging or monitoring AWS, Lambda workloads with skill template `aws-lambda-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [AWS, Lambda]
resource_types: [lambda_function]
access: read-only
---

# AWS Lambda Health Check

## Summary

This runbook provides a comprehensive guide to managing and troubleshooting AWS Lambda functions.

See [README.md](README.md) for additional context.

## Tools

### List Lambda Versions and Runtimes in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

This script is designed to list all the versions and runtimes of a specified AWS Lambda function.

- **Robot task name**: <code>List Lambda Versions and Runtimes in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `AWS`, `Lambda`, `Versions`, `Runtimes`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze AWS Lambda Invocation Errors in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region.

- **Robot task name**: <code>Analyze AWS Lambda Invocation Errors in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `AWS`, `Lambda`, `Error`, `Analysis`, `Invocation`, `Errors`, `CloudWatch`, `Logs`, `access:read-only`, `data:logs-regexp`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Monitor AWS Lambda Performance Metrics in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

This script is a bash utility for AWS Lambda functions the lists their notable metrics.

- **Robot task name**: <code>Monitor AWS Lambda Performance Metrics in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `AWS`, `Lambda`, `CloudWatch`, `Logs`, `Metrics`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Monitor AWS Lambda Invocation Errors

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Analyze AWS Lambda Invocation Errors in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region.

- **Robot task name**: <code>Analyze AWS Lambda Invocation Errors in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Sub-metric name**: `invocation_errors`
- **Tags**: `AWS`, `Lambda`, `Error`, `Analysis`, `Invocation`, `Errors`, `CloudWatch`, `Logs`, `data:logs-regexp`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AWS_REGION` | string | AWS Region | — | yes |
| `AWS_ACCOUNT_NAME` | string | AWS account name or alias for display purposes. | `Unknown` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `aws_credentials` | AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/aws-lambda-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/aws-lambda-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
bash analyze_lambda_invocation_errors.sh
bash list_lambda_runtimes.sh
bash monitor_aws_lambda_performance_metrics.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_lambda_invocation_errors.sh` — Bash helper script `analyze_lambda_invocation_errors.sh`.
- `list_lambda_runtimes.sh` — Bash helper script `list_lambda_runtimes.sh`.
- `monitor_aws_lambda_performance_metrics.sh` — Bash helper script `monitor_aws_lambda_performance_metrics.sh`.
