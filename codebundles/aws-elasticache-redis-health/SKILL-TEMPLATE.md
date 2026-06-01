---
name: aws-elasticache-redis-health
kind: skill-template
description: Checks the health status of Elasticache redis in the given region. Use when triaging or monitoring AWS, Elasticache, Redis workloads with skill template `aws-elasticache-redis-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [AWS, Elasticache, Redis]
resource_types: [elasticache_cluster]
access: read-only
---

# AWS ElastiCache Health Check

## Summary

This runbook provides a comprehensive guide to managing and troubleshooting AWS Elasticache Redis configurations.

See [README.md](README.md) for additional context.

## Tools

### Scan AWS Elasticache Redis Status in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Checks the high level metrics and status of the elasticache redis instances in the region.

- **Robot task name**: <code>Scan AWS Elasticache Redis Status in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `AWS`, `Elasticache`, `configuration`, `endpoint`, `configuration`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Monitors the health status of elasticache redis in the AWS region.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Scan ElastiCaches in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Performs a broad health scan of all Elasticache instances in the region.

- **Robot task name**: <code>Scan ElastiCaches in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Sub-metric name**: `redis_health`
- **Tags**: `bash`, `script`, `AWS`, `Elasticache`, `Health`, `data:config`
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
cd codebundles/aws-elasticache-redis-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/aws-elasticache-redis-health
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
bash analyze_aws_elasticache_redis_metrics.sh
bash monitor_redis_performance.sh
bash redis_status_scan.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_aws_elasticache_redis_metrics.sh` — Bash helper script `analyze_aws_elasticache_redis_metrics.sh`.
- `monitor_redis_performance.sh` — Bash helper script `monitor_redis_performance.sh`.
- `redis_status_scan.sh` — Bash helper script `redis_status_scan.sh`.
