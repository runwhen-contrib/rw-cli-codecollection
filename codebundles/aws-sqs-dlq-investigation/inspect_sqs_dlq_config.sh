#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: AWS_REGION
# Optional: SQS_QUEUE_URL, SQS_QUEUE_NAME (one of URL or NAME required)
# Writes: inspect_sqs_dlq_config_issues.json, sqs_dlq_state.json
# -----------------------------------------------------------------------------
source "$(dirname "$0")/auth.sh"
auth

: "${AWS_REGION:?Must set AWS_REGION}"

OUTPUT_ISSUES="inspect_sqs_dlq_config_issues.json"
STATE_FILE="sqs_dlq_state.json"
issues_json='[]'

add_issue() {
    local title="$1" details="$2" severity="$3" next_steps="$4"
    issues_json=$(echo "$issues_json" | jq \
        --arg t "$title" \
        --arg d "$details" \
        --argjson s "$severity" \
        --arg n "$next_steps" \
        '. += [{title: $t, details: $d, severity: ($s | tonumber), next_steps: $n}]')
}

arn_to_queue_url() {
    local arn="$1"
    local region account name
    region=$(echo "$arn" | cut -d: -f4)
    account=$(echo "$arn" | cut -d: -f5)
    name=$(echo "$arn" | cut -d: -f6)
    echo "https://sqs.${region}.amazonaws.com/${account}/${name}"
}

QUEUE_URL="${SQS_QUEUE_URL:-}"
if [[ -z "$QUEUE_URL" ]]; then
    if [[ -z "${SQS_QUEUE_NAME:-}" ]]; then
        add_issue "SQS queue not specified" "Set SQS_QUEUE_URL or SQS_QUEUE_NAME." 3 "Provide the primary queue URL or name for this SLX."
        echo "$issues_json" > "$OUTPUT_ISSUES"
        echo '{"error":"no_queue_identifier"}' > "$STATE_FILE"
        echo "Configuration inspection failed: missing queue identifier."
        exit 0
    fi
    if ! gu=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --region "$AWS_REGION" --output json 2>&1); then
        add_issue "Cannot resolve SQS queue URL" "get-queue-url failed for name \`$SQS_QUEUE_NAME\`: $gu" 3 "Verify the queue exists in $AWS_REGION and IAM allows sqs:GetQueueUrl."
        echo "$issues_json" > "$OUTPUT_ISSUES"
        echo '{"error":"get_queue_url_failed"}' > "$STATE_FILE"
        echo "$gu"
        exit 0
    fi
    QUEUE_URL=$(echo "$gu" | jq -r '.QueueUrl')
fi

if ! attrs_json=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names All \
    --region "$AWS_REGION" \
    --output json 2>&1); then
    add_issue "Cannot read primary queue attributes" "get-queue-attributes failed for \`$QUEUE_URL\`: $attrs_json" 3 "Verify sqs:GetQueueAttributes and that the queue URL is correct."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo '{"error":"get_attributes_failed"}' > "$STATE_FILE"
    echo "$attrs_json"
    exit 0
fi

ATTRS=$(echo "$attrs_json" | jq '.Attributes')
PRIMARY_ARN=$(echo "$ATTRS" | jq -r '.QueueArn // empty')
REDRIVE=$(echo "$ATTRS" | jq -r '.RedrivePolicy // empty')
VIS=$(echo "$ATTRS" | jq -r '.VisibilityTimeout // "unknown"')
RET=$(echo "$ATTRS" | jq -r '.MessageRetentionPeriod // "unknown"')
DLQ_ARN=""
DLQ_URL=""

echo "Primary queue: $QUEUE_URL"
echo "QueueArn: $PRIMARY_ARN"
echo "VisibilityTimeout(s): $VIS  Retention(s): $RET"

if [[ -z "$REDRIVE" || "$REDRIVE" == "null" ]]; then
    add_issue "No dead-letter redrive policy on primary queue" "Queue \`$PRIMARY_ARN\` has no RedrivePolicy. Failed messages may be dropped or require manual handling." 3 "Attach a redrive policy to a DLQ with maxReceiveCount appropriate for your workload."
else
    DLQ_ARN=$(echo "$REDRIVE" | jq -r '.deadLetterTargetArn // empty')
    MRC=$(echo "$REDRIVE" | jq -r '.maxReceiveCount // "unknown"')
    echo "RedrivePolicy: DLQ=$DLQ_ARN maxReceiveCount=$MRC"
    if [[ -z "$DLQ_ARN" ]]; then
        add_issue "Invalid RedrivePolicy" "RedrivePolicy present but deadLetterTargetArn missing." 3 "Fix the queue redrive policy in SQS configuration."
    else
        DLQ_URL=$(arn_to_queue_url "$DLQ_ARN")
        if ! dlq_attrs=$(aws sqs get-queue-attributes \
            --queue-url "$DLQ_URL" \
            --attribute-names QueueArn ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
            --region "$AWS_REGION" \
            --output json 2>&1); then
            add_issue "Cannot read DLQ attributes" "Failed to access DLQ \`$DLQ_ARN\` at URL \`$DLQ_URL\`: $dlq_attrs" 3 "Verify the DLQ exists, region/account match, and IAM allows sqs:GetQueueAttributes on the DLQ."
        fi
    fi
fi

REDRIVE_JSON="null"
if [[ -n "$REDRIVE" ]]; then
    REDRIVE_JSON=$(echo "$REDRIVE" | jq -c . 2>/dev/null || echo 'null')
fi

# Persist state for downstream tasks
jq -n \
    --arg purl "$QUEUE_URL" \
    --arg parn "$PRIMARY_ARN" \
    --argjson attrs "$ATTRS" \
    --argjson rp "$REDRIVE_JSON" \
    --arg dlq_arn "${DLQ_ARN}" \
    --arg dlq_url "${DLQ_URL}" \
    '{
      primary_queue_url: $purl,
      primary_queue_arn: $parn,
      primary_attributes: $attrs,
      redrive_policy: $rp,
      dlq_arn: (if $dlq_arn == "" then null else $dlq_arn end),
      dlq_url: (if $dlq_url == "" then null else $dlq_url end)
    }' > "$STATE_FILE"

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Configuration inspection completed. Issues -> $OUTPUT_ISSUES"
