#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads redrive/DLQ configuration and DLQ depth/age for target SQS queues.
# Writes: redrive_dlq_issues.json (issues array), sqs_investigation_context.json
# Env: AWS_REGION, SQS_QUEUE_URLS (optional), RESOURCES, DLQ_DEPTH_THRESHOLD (default 0),
#      DLQ_MAX_AGE_SECONDS (optional, default 3600; set to 0 to skip age checks)
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Must set AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sqs-common.sh
source "${SCRIPT_DIR}/sqs-common.sh"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

auth

OUTPUT_FILE="redrive_dlq_issues.json"
CONTEXT_FILE="sqs_investigation_context.json"
issues_json='[]'

DLQ_DEPTH_THRESHOLD="${DLQ_DEPTH_THRESHOLD:-0}"
DLQ_MAX_AGE_SECONDS="${DLQ_MAX_AGE_SECONDS:-3600}"

mapfile -t QUEUE_URLS < <(sqs_resolve_primary_urls || true)

if [[ ${#QUEUE_URLS[@]} -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No SQS queues matched" \
        --arg details "Set SQS_QUEUE_URLS to explicit queue URLs or adjust RESOURCES and ensure list-queues returns queues in this region." \
        --argjson severity 3 \
        --arg next_steps "Verify SQS_QUEUE_URLS or RESOURCES (substring match on queue name) and IAM sqs:ListQueues." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo '[]' > "$CONTEXT_FILE"
    echo "No queues to analyze."
    exit 0
fi

context_entries='[]'

for primary_url in "${QUEUE_URLS[@]}"; do
    echo "Analyzing primary queue: $primary_url"
    primary_arn=$(sqs_get_queue_arn "$primary_url" || echo "")
    if [[ -z "$primary_arn" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Cannot read queue ARN for \`$primary_url\`" \
            --arg details "get-queue-attributes failed." \
            --argjson severity 4 \
            --arg next_steps "Verify the queue URL, region, and sqs:GetQueueAttributes." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        continue
    fi

    attrs=$(aws sqs get-queue-attributes \
        --region "$AWS_REGION" \
        --queue-url "$primary_url" \
        --attribute-names All \
        --output json 2>/dev/null) || attrs="{}"

    redrive=$(echo "$attrs" | jq -r '.Attributes.RedrivePolicy // empty')
    dlq_arn=""
    max_receive=""

    if [[ -z "$redrive" || "$redrive" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No dead-letter redrive policy on \`$primary_arn\`" \
            --arg details "This queue has no RedrivePolicy; failed messages may be dropped or retried indefinitely without a DLQ." \
            --argjson severity 3 \
            --arg next_steps "Configure a dead-letter queue and redrive policy on the primary queue." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        context_entries=$(echo "$context_entries" | jq \
            --arg pu "$primary_url" \
            --arg pa "$primary_arn" \
            '. += [{
              "primary_url": $pu,
              "primary_arn": $pa,
              "dlq_url": "",
              "dlq_arn": "",
              "max_receive_count": null
            }]')
        continue
    fi

    dlq_arn=$(echo "$redrive" | jq -r '.deadLetterTargetArn // empty')
    max_receive=$(echo "$redrive" | jq -r '.maxReceiveCount // empty')

    if [[ -z "$dlq_arn" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Invalid RedrivePolicy on \`$primary_arn\`" \
            --arg details "RedrivePolicy missing deadLetterTargetArn: $redrive" \
            --argjson severity 3 \
            --arg next_steps "Fix RedrivePolicy JSON on the queue." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        continue
    fi

    dlq_name=$(sqs_arn_to_name "$dlq_arn")
    dlq_url=$(aws sqs get-queue-url --region "$AWS_REGION" --queue-name "$dlq_name" --output json 2>/dev/null | jq -r '.QueueUrl // empty') || dlq_url=""

    if [[ -z "$dlq_url" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Cannot resolve DLQ URL for \`$dlq_arn\`" \
            --arg details "get-queue-url failed for DLQ name \`$dlq_name\`." \
            --argjson severity 3 \
            --arg next_steps "Verify the DLQ exists in this account/region and IAM sqs:GetQueueUrl." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
        continue
    fi

    dlq_attrs=$(aws sqs get-queue-attributes \
        --region "$AWS_REGION" \
        --queue-url "$dlq_url" \
        --attribute-names ApproximateNumberOfMessagesVisible ApproximateAgeOfOldestMessage \
        --output json 2>/dev/null) || dlq_attrs="{}"

    visible=$(echo "$dlq_attrs" | jq -r '.Attributes.ApproximateNumberOfMessagesVisible // "0"')
    age=$(echo "$dlq_attrs" | jq -r '.Attributes.ApproximateAgeOfOldestMessage // "0"')
    visible=${visible:-0}
    age=${age:-0}

    thresh="$DLQ_DEPTH_THRESHOLD"
    if [[ "$visible" =~ ^[0-9]+$ ]] && [[ "$thresh" =~ ^[0-9]+$ ]]; then
        if (( visible > thresh )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "DLQ backlog on \`$dlq_name\` (primary \`$primary_arn\`)" \
                --arg details "ApproximateNumberOfMessagesVisible=$visible (threshold $thresh). ApproximateAgeOfOldestMessage=${age}s. maxReceiveCount=$max_receive" \
                --argjson severity 2 \
                --arg next_steps "Review peeked messages and Lambda logs; redrive or fix poison pills after root cause is fixed." \
                '. += [{
                  "title": $title,
                  "details": $details,
                  "severity": $severity,
                  "next_steps": $next_steps
                }]')
        fi
    fi

    if [[ "$DLQ_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] && [[ "$DLQ_MAX_AGE_SECONDS" -gt 0 ]]; then
        if [[ "$visible" =~ ^[0-9]+$ ]] && [[ "$age" =~ ^[0-9]+$ ]]; then
            if (( visible > 0 && age > ${DLQ_MAX_AGE_SECONDS} )); then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Stale messages in DLQ \`$dlq_name\`" \
                    --arg details "Oldest message age ${age}s exceeds ${DLQ_MAX_AGE_SECONDS}s with visible=$visible." \
                    --argjson severity 3 \
                    --arg next_steps "Investigate processing failures; consider redrive after fixing consumers." \
                    '. += [{
                      "title": $title,
                      "details": $details,
                      "severity": $severity,
                      "next_steps": $next_steps
                    }]')
            fi
        fi
    fi

    context_entries=$(echo "$context_entries" | jq \
        --arg pu "$primary_url" \
        --arg pa "$primary_arn" \
        --arg du "$dlq_url" \
        --arg da "$dlq_arn" \
        --arg mrc "${max_receive}" \
        '. += [{
          "primary_url": $pu,
          "primary_arn": $pa,
          "dlq_url": $du,
          "dlq_arn": $da,
          "max_receive_count": (if ($mrc | length) == 0 then null else ($mrc | tonumber) end)
        }]')
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "$context_entries" | jq '{ "queues": . }' > "$CONTEXT_FILE"
echo "Wrote $OUTPUT_FILE and $CONTEXT_FILE"
jq . "$OUTPUT_FILE"
