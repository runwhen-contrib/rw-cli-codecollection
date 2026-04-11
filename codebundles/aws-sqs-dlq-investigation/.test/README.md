# Testing aws-sqs-dlq-investigation

This directory contains test infrastructure for the `aws-sqs-dlq-investigation` CodeBundle. Terraform provisions real AWS resources (SQS queues, DLQs, a Lambda consumer) to validate generation rules and optionally run the CodeBundle end-to-end.

## Test Scenarios

| Scenario | Resources | Expected Outcome |
|----------|-----------|------------------|
| **healthy_queues** | Primary queue with RedrivePolicy → empty DLQ | 0 issues |
| **dlq_backlog** | Primary queue + DLQ seeded with messages, Lambda consumer with error logs | 3 issues (severity 2, 3) |

## Prerequisites

- Bash, Terraform >= 1.0, AWS CLI v2, Docker
- An AWS account with permissions: SQS, Lambda, IAM, CloudWatch Logs, STS
- [Task](https://taskfile.dev/) runner

## Setup

### 1. Create `terraform/tf.secret`

This file is gitignored and must be created manually:

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
```

### 2. Build test infrastructure

```bash
task build-infra
```

This runs `terraform apply` which creates:
- **Healthy pair**: `rw-sqs-dlq-test-healthy-primary` queue + `rw-sqs-dlq-test-healthy-dlq` (empty)
- **Unhealthy pair**: `rw-sqs-dlq-test-unhealthy-primary` queue + `rw-sqs-dlq-test-unhealthy-dlq` (seeded with messages)
- A Lambda function (`rw-sqs-dlq-test-failing-consumer`) with an event source mapping to the unhealthy primary queue
- CloudWatch Logs entries from a single Lambda invocation (error logs for log-correlation testing)

### 3. Run discovery

```bash
task
```

This checks for unpushed commits, generates `workspaceInfo.yaml`, and starts RunWhen Local discovery. Generated SLXs appear under `output/workspaces/`.

### 4. Validate generation rules (optional)

```bash
task validate-generation-rules
```

Requires `curl`, `yq`, and `ajv` (installed via `npm install -g ajv-cli`).

### 5. Upload SLXs to RunWhen Platform (optional)

Set `RW_WORKSPACE`, `RW_API_URL`, and `RW_PAT` in `terraform/tf.secret`, then:

```bash
task upload-slxs
```

## Cleanup

```bash
task clean
```

This destroys Terraform resources, deletes uploaded SLXs, and removes discovery output.

## Static validation only

To run `bash -n` syntax checks on all CodeBundle shell scripts without AWS credentials:

```bash
task validate
```
