#!/usr/bin/env bash
# Lists source queues, resolves RedrivePolicy DLQs, dedupes by DLQ ARN, and opens issues when DLQ depth exceeds DEAD_LETTER_MESSAGE_THRESHOLD.
# Writes JSON issues to dlq_depth_issues.json (jq).

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/auth.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/sqs_dlq_common.sh"

auth

: "${AWS_REGION:?Must set AWS_REGION}"

OUTPUT_FILE="dlq_depth_issues.json"
THRESHOLD="${DEAD_LETTER_MESSAGE_THRESHOLD:-0}"
issues_json='[]'

echo "=== SQS DLQ depth and redrive (region=${AWS_REGION}, threshold=${THRESHOLD}) ==="

SOURCE_URLS=()
if [[ -n "${SQS_QUEUE_URL:-}" || -n "${SQS_QUEUE_URLS:-}" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(rw_sqs_collect_source_urls)
else
    prefix="${SQS_QUEUE_NAME_PREFIX:-}"
    if ! raw=$(aws sqs list-queues --region "$AWS_REGION" ${prefix:+--queue-name-prefix "$prefix"} --output json 2>/dev/null); then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Cannot list SQS queues in \`${AWS_REGION}\`" \
            --arg details "aws sqs list-queues failed. Check IAM (sqs:ListQueues) and region." \
            --argjson severity 4 \
            --arg next_steps "Verify AWS credentials, region, and sqs:ListQueues permission." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        echo "$issues_json" > "$OUTPUT_FILE"
        exit 0
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(echo "$raw" | jq -r '.QueueUrls[]? // empty')
fi

if [[ ${#SOURCE_URLS[@]} -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No source SQS queues to evaluate" \
        --arg details "Set SQS_QUEUE_URL, SQS_QUEUE_URLS, or use discovery with SQS_QUEUE_NAME_PREFIX so at least one queue is in scope." \
        --argjson severity 3 \
        --arg next_steps "Configure SQS_QUEUE_URLS or adjust SQS_QUEUE_NAME_PREFIX / discovery rules." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

declare -A SEEN_DLQ

for src in "${SOURCE_URLS[@]}"; do
    [[ -z "$src" ]] && continue
    echo "--- Source queue: ${src}"
    attrs=$(aws sqs get-queue-attributes --queue-url "$src" --attribute-names QueueArn,RedrivePolicy --output json 2>/dev/null || echo '{}')
    qarn=$(echo "$attrs" | jq -r '.Attributes.QueueArn // empty')
    policy=$(echo "$attrs" | jq -r '.Attributes.RedrivePolicy // empty')
    if [[ -z "$policy" || "$policy" == "null" ]]; then
        echo "No RedrivePolicy on source queue (no DLQ configured via SQS redrive)."
        continue
    fi
    resolved=$(rw_sqs_resolve_dlq_url "$src" || true)
    if [[ -z "$resolved" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Cannot resolve DLQ for source queue" \
            --arg details "Source: ${src}. RedrivePolicy present but get-queue-url failed (wrong account/region or IAM sqs:GetQueueUrl)." \
            --argjson severity 3 \
            --arg next_steps "Verify DLQ exists in this account/region and IAM allows sqs:GetQueueUrl on the DLQ." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        continue
    fi
    dlq_arn="${resolved%%|*}"
    dlq_url="${resolved##*|}"
    if [[ -n "${SEEN_DLQ[$dlq_arn]:-}" ]]; then
        echo "Skipping duplicate DLQ ARN ${dlq_arn}"
        continue
    fi
    SEEN_DLQ[$dlq_arn]=1

    depth=$(rw_sqs_queue_depth "$dlq_url")
    echo "DLQ ${dlq_url} depth=${depth}"

    if [[ "$depth" =~ ^[0-9]+$ ]] && [[ "$depth" -gt "$THRESHOLD" ]]; then
        sev=2
        if [[ "$depth" -gt 1000 ]]; then
            sev=3
        fi
        max_recv=$(echo "$policy" | jq -r '.maxReceiveCount // "unknown"')
        issues_json=$(echo "$issues_json" | jq \
            --arg title "DLQ message depth exceeds threshold for \`${dlq_arn}\`" \
            --arg details "ApproximateNumberOfMessages on DLQ: ${depth}. Threshold (DEAD_LETTER_MESSAGE_THRESHOLD): ${THRESHOLD}. Source queue ARN: ${qarn}. Redrive maxReceiveCount: ${max_recv}." \
            --argjson severity "$sev" \
            --arg next_steps "Inspect consumer failures (Lambda logs, ECS tasks, or workers). Sample messages, fix poison payloads, then redrive or purge as appropriate. See DLQ sample and Lambda logs tasks in this bundle." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
    fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
exit 0
