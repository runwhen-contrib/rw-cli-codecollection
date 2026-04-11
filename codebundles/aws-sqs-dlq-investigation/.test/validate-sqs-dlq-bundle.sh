#!/usr/bin/env bash
# Static validation for aws-sqs-dlq-investigation (syntax only; no AWS calls).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "Validating bash scripts under ${ROOT}"
for f in \
  "${ROOT}/auth.sh" \
  "${ROOT}/sqs-common.sh" \
  "${ROOT}/sqs-redrive-and-dlq-depth.sh" \
  "${ROOT}/sqs-peek-dlq-messages.sh" \
  "${ROOT}/sqs-discover-lambda-consumers.sh" \
  "${ROOT}/sqs-fetch-lambda-error-logs.sh" \
  "${ROOT}/sqs-cloudwatch-queue-metrics.sh"
do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f"
    exit 1
  fi
  bash -n "$f"
done
echo "OK: bash -n passed for all scripts."
