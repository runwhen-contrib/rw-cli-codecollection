# AWS SQS Dead Letter Queue Health and Log Correlation

This CodeBundle monitors Amazon SQS dead-letter queues (DLQs) tied to source queues via `RedrivePolicy`, raises issues when messages accumulate past a threshold, samples recent DLQ payloads for diagnostics, correlates Lambda event source consumers to CloudWatch Logs, and pulls source-queue CloudWatch metrics for backlog context.

## Overview

- **DLQ depth and redrive**: Discovers source queues (explicit URLs or `list-queues` with an optional prefix), resolves each DLQ from `RedrivePolicy`, dedupes checks by DLQ ARN, and compares `ApproximateNumberOfMessages` to `DEAD_LETTER_MESSAGE_THRESHOLD`.
- **DLQ sampling**: Receives up to `MAX_DLQ_MESSAGES_TO_SAMPLE` messages per run with a short visibility timeout, extracts attributes and body snippets, then resets visibility to zero so messages remain available (delete is not used by default).
- **Lambda logs**: Lists Lambda event source mappings for each source queue ARN and searches `/aws/lambda/<function>` log groups for error patterns in the lookback window. If the DLQ has traffic but there is no Lambda mapping, the task reports that non-Lambda consumers (ECS, EC2, etc.) need manual correlation.
- **Source metrics**: Reads `AWS/SQS` metrics (`ApproximateAgeOfOldestMessage`, `NumberOfMessagesSent`, `NumberOfMessagesDeleted`) and flags sustained high oldest-message age.

SQS does not expose Azure-style `DeadLetterReason` on the queue API; root cause typically comes from message bodies (for example Lambda failure payloads), consumer logs, or application attributes.

## Configuration

### Required Variables

- `AWS_REGION`: AWS region containing the queues.

### Optional Variables

- `AWS_ACCOUNT_NAME`: Account display label for reports (default: `Unknown`).
- `SQS_QUEUE_URL`: Optional single source queue URL (often supplied by discovery as a qualifier alongside `SQS_QUEUE_URLS`).
- `SQS_QUEUE_URLS`: Comma-separated source queue URLs; when empty, discovery uses `aws sqs list-queues` with optional `SQS_QUEUE_NAME_PREFIX`.
- `SQS_QUEUE_NAME_PREFIX`: Prefix passed to `list-queues` when no explicit URLs are set (default: empty).
- `DEAD_LETTER_MESSAGE_THRESHOLD`: Open a DLQ depth issue when approximate message count is **greater than** this integer (default: `0`, meaning any message triggers when depth exceeds zero).
- `CLOUDWATCH_LOG_LOOKBACK_MINUTES`: Window for Lambda log search and metric alignment (default: `30`).
- `MAX_DLQ_MESSAGES_TO_SAMPLE`: Cap on DLQ messages to receive per run for diagnostics (default: `5`).

### Secrets

- `aws_credentials`: Standard RunWhen AWS credentials (`aws-auth` block): access keys, IRSA, or assume-role via workspace configuration.

## Tasks Overview

### Check Dead Letter Queue Depth and Redrive Configuration

Evaluates DLQ depth against the threshold and surfaces redrive metadata (`maxReceiveCount`). Emits issues when depth is above the configured limit.

### Sample Recent Dead Letter Messages for Diagnostics

Pulls a bounded sample per run, returns visibility to zero after inspection, and emits structured issues containing message metadata and truncated bodies (including Lambda async failure shapes when present).

### Correlate DLQ to Lambda Consumer CloudWatch Logs

Finds Lambda functions subscribed to the source queue and scans recent log events for error-oriented patterns. If messages are in the DLQ but the consumer is not Lambda, the task explains the limitation and points operators to other platforms.

### Collect Source Queue CloudWatch Metrics for Context

Emits CloudWatch metric datapoints to the report and opens issues when `ApproximateAgeOfOldestMessage` stays above 300 seconds in the window (configurable only in script today; threshold is documented in task output).

## IAM

Typical read-only permissions: `sqs:GetQueueAttributes`, `sqs:ListQueues`, `sqs:ReceiveMessage` (DLQ), `sqs:GetQueueUrl`, `lambda:ListEventSourceMappings`, `logs:FilterLogEvents`, `logs:DescribeLogGroups`, `cloudwatch:GetMetricStatistics`.
