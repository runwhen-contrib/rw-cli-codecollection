# Testing aws-sqs-dlq-investigation

This directory holds lightweight validation for the CodeBundle. Full AWS integration tests require credentials and real SQS queues.

## Prerequisites

- Bash

## Quick start

From this directory:

```bash
task
```

This runs `validate-sqs-dlq-bundle.sh`, which performs `bash -n` syntax checks on all bundle shell scripts.

## Live AWS tests

Provision queues and a Lambda event source mapping in a non-production account, configure `aws-auth` in RunWhen Local, and run the CodeBundle against `SQS_QUEUE_URLS` pointing at a primary queue with an attached DLQ.
