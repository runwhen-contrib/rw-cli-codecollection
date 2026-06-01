---
name: aws-sqs-dlq-investigation
kind: skill-template
description: Investigates Amazon SQS dead-letter queues by correlating queue configuration, DLQ backlog, sampled messages, Lambda... Use when triaging or monitoring AWS, SQS, Lambda workloads with skill templat...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [AWS, SQS, Lambda, CloudWatch]
resource_types: [sqs_queue]
access: read-only
---

# AWS SQS Dead Letter Queue Investigation

## Summary

This CodeBundle detects messages that have landed on an SQS dead-letter queue (DLQ), quantifies backlog, samples DLQ payloads, finds Lambda consumers via event source mappings, pulls recent processor errors from CloudWatch Logs, and snapshots queue metrics—mirroring the queue-plus-logs workflow used for Azure Service Bus health on RunWhen.

See [README.md](README.md) for additional context.

## Tools

### Check SQS Redrive Policy and DLQ Depth for Queues in `${AWS_REGION}` `${AWS_ACCOUNT_NAME}`

Reads RedrivePolicy and DLQ attributes, flags backlog versus DLQ_DEPTH_THRESHOLD and stale message age.

- **Robot task name**: <code>Check SQS Redrive Policy and DLQ Depth for Queues in `${AWS_REGION}` `${AWS_ACCOUNT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sqs-redrive-and-dlq-depth.sh`
- **Tags**: `AWS`, `SQS`, `DLQ`, `access:read-only`, `data:metrics`
- **Reads**: `AWS_REGION`
- **Writes**: `redrive_dlq_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Peek Sample Messages on Dead Letter Queues in `${AWS_REGION}`

Non-destructively receives a limited batch from each DLQ with a short visibility timeout for operator review.

- **Robot task name**: <code>Peek Sample Messages on Dead Letter Queues in `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sqs-peek-dlq-messages.sh`
- **Tags**: `AWS`, `SQS`, `DLQ`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AWS_REGION`
- **Writes**: `peek_dlq_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Discover Lambda Consumers for SQS Queues in `${AWS_REGION}`

Lists Lambda event source mappings for each primary queue ARN to support log correlation.

- **Robot task name**: <code>Discover Lambda Consumers for SQS Queues in `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sqs-discover-lambda-consumers.sh`
- **Tags**: `AWS`, `Lambda`, `SQS`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`
- **Writes**: `discover_lambda_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Recent Lambda Processor Errors from CloudWatch Logs in `${AWS_REGION}`

Searches Lambda (and optional extra) log groups for errors within the lookback window.

- **Robot task name**: <code>Fetch Recent Lambda Processor Errors from CloudWatch Logs in `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sqs-fetch-lambda-error-logs.sh`
- **Tags**: `AWS`, `CloudWatch`, `Logs`, `Lambda`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AWS_REGION`
- **Writes**: `fetch_lambda_logs_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Summarize CloudWatch Metrics for SQS Queues and DLQs in `${AWS_REGION}`

Optional traffic and backlog snapshot via CloudWatch metrics for the primary queue and DLQ.

- **Robot task name**: <code>Summarize CloudWatch Metrics for SQS Queues and DLQs in `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sqs-cloudwatch-queue-metrics.sh`
- **Tags**: `AWS`, `SQS`, `CloudWatch`, `access:read-only`, `data:metrics`
- **Reads**: `AWS_REGION`
- **Writes**: `cloudwatch_queue_metrics_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures SQS DLQ health as a 0–1 score: 1 when redrive/DLQ analysis reports no issues, otherwise 0.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score DLQ Clearance for SQS Queues in `${AWS_REGION}`

Runs the redrive/DLQ depth check and maps an empty issue list to score 1, else 0.

- **Robot task name**: <code>Score DLQ Clearance for SQS Queues in `${AWS_REGION}`</code>
- **Sub-metric name**: `dlq_issue_count_clear`
- **Underlying script**: `sqs-redrive-and-dlq-depth.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `AWS_REGION`
- **Pass condition**: `${n} == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AWS_REGION` | string | AWS region containing the queues. | — | yes |
| `AWS_ACCOUNT_NAME` | string | Human-readable account alias for titles and reports. | `` | yes |
| `SQS_QUEUE_URLS` | string | Comma-separated primary SQS queue URLs (optional if listing by RESOURCES). | `` | yes |
| `RESOURCES` | string | Queue name substring filter or All for discovery-driven runs. | `All` | no |
| `DLQ_DEPTH_THRESHOLD` | string | Flag DLQ when ApproximateNumberOfMessagesVisible exceeds this value (0 means any message is an issue). | `0` | no |
| `CLOUDWATCH_LOG_LOOKBACK_MINUTES` | string | How far back to search processor logs for errors. | `60` | no |
| `EXTRA_LOG_GROUP_NAMES` | string | Optional extra CloudWatch log groups for non-Lambda processors. | `` | yes |
| `MAX_DLQ_SAMPLE_MESSAGES` | string | Maximum DLQ messages to sample per queue in one run. | `5` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `aws_credentials` | AWS credentials from the workspace aws-auth block. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `redrive_dlq_issues.json`
- `peek_dlq_issues.json`
- `discover_lambda_issues.json`
- `fetch_lambda_logs_issues.json`
- `cloudwatch_queue_metrics_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/aws-sqs-dlq-investigation/runbook.robot`
- **Monitor**: `codebundles/aws-sqs-dlq-investigation/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/aws-sqs-dlq-investigation
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
export SQS_QUEUE_URLS=...
export RESOURCES=...
export DLQ_DEPTH_THRESHOLD=...
export CLOUDWATCH_LOG_LOOKBACK_MINUTES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/aws-sqs-dlq-investigation
export AWS_REGION=...
export AWS_ACCOUNT_NAME=...
export SQS_QUEUE_URLS=...
export RESOURCES=...
bash sqs-cloudwatch-queue-metrics.sh
bash sqs-common.sh
bash sqs-discover-lambda-consumers.sh
bash sqs-fetch-lambda-error-logs.sh
bash sqs-peek-dlq-messages.sh
bash sqs-redrive-and-dlq-depth.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `sqs-cloudwatch-queue-metrics.sh` — Bash helper script `sqs-cloudwatch-queue-metrics.sh`.
- `sqs-common.sh` — Bash helper script `sqs-common.sh`.
- `sqs-discover-lambda-consumers.sh` — Bash helper script `sqs-discover-lambda-consumers.sh`.
- `sqs-fetch-lambda-error-logs.sh` — Bash helper script `sqs-fetch-lambda-error-logs.sh`.
- `sqs-peek-dlq-messages.sh` — Bash helper script `sqs-peek-dlq-messages.sh`.
- `sqs-redrive-and-dlq-depth.sh` — Bash helper script `sqs-redrive-and-dlq-depth.sh`.
