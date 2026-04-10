# AWS SQS Dead Letter Queue Investigation

This CodeBundle detects messages that have landed on an SQS dead-letter queue (DLQ), quantifies backlog, samples DLQ payloads, finds Lambda consumers via event source mappings, pulls recent processor errors from CloudWatch Logs, and snapshots queue metrics—mirroring the queue-plus-logs workflow used for Azure Service Bus health on RunWhen.

## Overview

- **Redrive and DLQ depth**: Reads `RedrivePolicy`, resolves the DLQ, and flags visible depth and oldest-message age versus thresholds.
- **Peek DLQ messages**: Non-destructive receive with a short visibility timeout for operator review (bodies truncated in output).
- **Lambda discovery**: Lists event source mappings for each primary queue ARN.
- **CloudWatch Logs**: Scans `/aws/lambda/...` and optional extra log groups for error patterns in a configurable lookback window.
- **CloudWatch metrics**: Short-window sums for traffic and backlog metrics on the primary queue and DLQ.

## Configuration

### Required variables

- `AWS_REGION`: AWS Region for API calls (for example `us-east-1`).

### Optional variables

- `AWS_ACCOUNT_NAME`: Human-readable account alias for report titles (default: empty).
- `SQS_QUEUE_URLS`: Comma-separated **primary** queue URLs. When empty, queues are listed with `ListQueues` and filtered by `RESOURCES`.
- `RESOURCES`: Queue name substring to match, or `All` to include every listed queue when `SQS_QUEUE_URLS` is not set (default: `All`).
- `DLQ_DEPTH_THRESHOLD`: Flag the DLQ when `ApproximateNumberOfMessagesVisible` is **strictly greater** than this integer. Default `0` means any visible message is an issue.
- `CLOUDWATCH_LOG_LOOKBACK_MINUTES`: Lookback for `filter-log-events` (default: `60`).
- `EXTRA_LOG_GROUP_NAMES`: Comma-separated extra CloudWatch log groups (for example Fargate or ECS application logs).
- `MAX_DLQ_SAMPLE_MESSAGES`: Cap on messages to receive per DLQ per run (default: `5`).

### Secrets

- `aws_credentials`: Standard AWS credentials from the workspace `aws-auth` block (access key, assumed role, IRSA, or instance profile), consistent with other `rw-cli` AWS CodeBundles.

## Tasks overview

### Check SQS Redrive Policy and DLQ Depth

Evaluates redrive configuration, DLQ depth, and stale message age; writes JSON issues and `sqs_investigation_context.json` for downstream tasks.

### Peek Sample Messages on the Dead Letter Queue

Samples up to `MAX_DLQ_SAMPLE_MESSAGES` messages per DLQ without deletion (short visibility timeout).

### Discover Lambda Consumers for the Queue

Lists Lambda event source mappings for the primary queue ARN(s). If none are found, issues include next steps for ECS/EKS or `EXTRA_LOG_GROUP_NAMES`.

### Fetch Recent Lambda Processor Errors from CloudWatch Logs

Runs CloudWatch Logs `filter-log-events` for ERROR / timeout / runtime-style patterns over the lookback window.

### Summarize CloudWatch Metrics for Queue and DLQ

Emits a fifteen-minute Sum snapshot for standard `AWS/SQS` metrics on the primary queue and DLQ.

## IAM

Typical read-only permissions: `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`, `sqs:ListQueues`, `sqs:ReceiveMessage`, `lambda:ListEventSourceMappings`, `logs:FilterLogEvents`, `cloudwatch:GetMetricStatistics`, `sts:GetCallerIdentity`.
