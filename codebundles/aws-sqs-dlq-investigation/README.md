# AWS SQS Dead-Letter Queue Investigation

When messages land in an Amazon SQS dead-letter queue (DLQ), this CodeBundle gathers queue and redrive configuration, DLQ depth and age signals, Lambda event source mappings, and CloudWatch log excerpts so operators can see why processing failed and what to do next.

## Overview

- **Configuration**: Validates the primary queue URL or name, reads attributes and `RedrivePolicy`, and confirms the DLQ is reachable.
- **Metrics**: Reports approximate DLQ message count and `ApproximateAgeOfOldestMessage` from CloudWatch.
- **Lambda discovery**: Finds Lambda functions with event source mappings for the queue so `/aws/lambda/...` log groups are known.
- **Logs**: Scans Lambda and optional log groups for error patterns over a configurable lookback window.
- **Summary**: Produces a concise report and highlights when DLQ backlog aligns with log evidence of failures.

### Limitations

- SQS does not always store a human-readable failure reason on the message; correlation relies on consumer logs and timing.
- High-volume log groups may require tighter lookback windows or CloudWatch Logs Insights in the AWS console.
- FIFO queues, SNS fan-in, and cross-account consumers may need extra manual scope (additional `CLOUDWATCH_LOG_GROUPS` and IAM).

## Configuration

### Required variables

- `AWS_REGION`: AWS Region where the primary queue and DLQ live.

### Optional variables

- `AWS_ACCOUNT_NAME`: Human-readable account alias or name for reports (default: `Unknown`).
- `SQS_QUEUE_URL`: Full `https://sqs...` URL of the primary queue when known (preferred for exact targeting).
- `SQS_QUEUE_NAME`: Primary queue name when the URL should be resolved with `GetQueueUrl` (use when URL is not supplied).
- `CLOUDWATCH_LOG_GROUPS`: Comma-separated extra log group names (ECS, EC2, applications) beyond discovered Lambda groups.
- `LOG_LOOKBACK_MINUTES`: Log search lookback in minutes (default: `120`).
- `DLQ_DEPTH_THRESHOLD`: Raise a metrics issue when approximate DLQ messages exceed this integer (default: `0`).
- `TIMEOUT_SECONDS`: Timeout for most bash tasks in seconds (default: `240`).
- `QUERY_TIMEOUT_SECONDS`: Timeout for the CloudWatch log search task in seconds (default: `300`).

### Secrets

- `aws_credentials`: AWS credentials from the workspace `aws-auth` block (IRSA, access keys, assume role). Maps to the AWS CLI environment for read-only `sqs`, `lambda`, `logs`, and `cloudwatch` APIs.

## Tasks overview

### Inspect SQS Queue and DLQ Configuration

Reads queue attributes and redrive policy; flags missing redrive configuration or unreachable DLQ.

### Report DLQ Depth and Age Signals

Uses `GetQueueAttributes` and CloudWatch metrics for backlog depth and oldest-message age; compares depth to `DLQ_DEPTH_THRESHOLD`.

### Discover Lambda Event Source Mappings for Queue

Lists Lambda event source mappings for the primary queue ARN and records function names for log targeting.

### Query CloudWatch Logs for Processing Failures

Runs `filter-log-events` across discovered Lambda log groups and optional groups for error-oriented patterns.

### Summarize DLQ Triage Findings

Builds a short narrative summary and can raise a cross-cutting issue when DLQ messages exist alongside log hits.
