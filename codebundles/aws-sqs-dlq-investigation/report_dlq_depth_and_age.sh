#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Uses sqs_dlq_state.json from inspect. Writes report_dlq_depth_issues.json
# Env: DLQ_DEPTH_THRESHOLD (default 0), AWS_REGION
# -----------------------------------------------------------------------------
source "$(dirname "$0")/auth.sh"
auth

: "${AWS_REGION:?Must set AWS_REGION}"

STATE_FILE="sqs_dlq_state.json"
OUTPUT_ISSUES="report_dlq_depth_issues.json"
THRESHOLD="${DLQ_DEPTH_THRESHOLD:-0}"
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

if [[ ! -f "$STATE_FILE" ]]; then
    add_issue "Missing triage state file" "Expected $STATE_FILE from Inspect task. Run Inspect SQS Queue and DLQ Configuration first." 3 "Re-run tasks in order starting with configuration inspection."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo "No state file."
    exit 0
fi

DLQ_URL=$(jq -r '.dlq_url // empty' "$STATE_FILE")
DLQ_ARN=$(jq -r '.dlq_arn // empty' "$STATE_FILE")
PRIMARY_ARN=$(jq -r '.primary_queue_arn // empty' "$STATE_FILE")

if [[ -z "$DLQ_URL" ]]; then
    add_issue "No DLQ configured" "Primary queue \`$PRIMARY_ARN\` has no associated DLQ URL in state (missing redrive policy or unresolved DLQ)." 3 "Configure a dead-letter queue and redrive policy, then re-run inspection."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    exit 0
fi

if ! attrs=$(aws sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
    --region "$AWS_REGION" \
    --output json 2>&1); then
    add_issue "Cannot read DLQ depth" "get-queue-attributes failed: $attrs" 3 "Verify IAM sqs:GetQueueAttributes on the DLQ."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo "$attrs"
    exit 0
fi

APPROX=$(echo "$attrs" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
echo "DLQ approximate visible messages: $APPROX"

# CloudWatch: age of oldest message (may be empty if no samples)
QUEUE_NAME=$(echo "$DLQ_URL" | awk -F/ '{print $NF}')
START_TS=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

AGE_STAT="0"
if age_raw=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/SQS \
    --metric-name ApproximateAgeOfOldestMessage \
    --dimensions Name=QueueName,Value="$QUEUE_NAME" \
    --start-time "$START_TS" \
    --end-time "$END_TS" \
    --period 60 \
    --statistics Maximum \
    --region "$AWS_REGION" \
    --output json 2>&1); then
    AGE_STAT=$(echo "$age_raw" | jq '[.Datapoints[].Maximum] | max // 0')
    echo "ApproximateAgeOfOldestMessage (recent max): $AGE_STAT"
else
    echo "Note: could not query age metric: $age_raw"
fi

# Merge metrics into state
tmp=$(mktemp)
jq --arg approx "$APPROX" --argjson age "$AGE_STAT" \
    '. + {dlq_approximate_messages: ($approx | tonumber), dlq_age_seconds: $age}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

TNUM=$(echo "$THRESHOLD" | tr -d '[:space:]')
if [[ -z "$TNUM" ]]; then TNUM=0; fi

if [[ "$APPROX" =~ ^[0-9]+$ ]] && [[ "$APPROX" -gt "$TNUM" ]]; then
    add_issue "DLQ depth above threshold" "DLQ \`$DLQ_ARN\` has ApproximateNumberOfMessages=$APPROX (threshold $TNUM). ${AGE_STAT:+Oldest message age (metric max): ${AGE_STAT}s}" 2 "Drain or replay DLQ after fixing the consumer; investigate Lambda logs in the next tasks."
fi

# Non-zero DLQ with threshold 0 is common alert case — already covered when THRESHOLD is 0 and APPROX > 0

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "DLQ depth report completed. Issues -> $OUTPUT_ISSUES"
