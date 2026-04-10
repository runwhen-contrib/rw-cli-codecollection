#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists Lambda event source mappings for the primary queue ARN.
# Writes lambda_esm_functions.json (array of function names) and discover_lambda_esm_issues.json
# -----------------------------------------------------------------------------
source "$(dirname "$0")/auth.sh"
auth

: "${AWS_REGION:?Must set AWS_REGION}"

STATE_FILE="sqs_dlq_state.json"
OUT_FUNCS="lambda_esm_functions.json"
OUTPUT_ISSUES="discover_lambda_esm_issues.json"
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
    add_issue "Missing triage state file" "Expected $STATE_FILE. Run Inspect task first." 3 "Run Inspect SQS Queue and DLQ Configuration before discovery."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo '[]' > "$OUT_FUNCS"
    exit 0
fi

PRIMARY_ARN=$(jq -r '.primary_queue_arn // empty' "$STATE_FILE")
if [[ -z "$PRIMARY_ARN" ]]; then
    add_issue "Missing primary queue ARN in state" "Cannot list event source mappings without QueueArn." 3 "Re-run configuration inspection."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo '[]' > "$OUT_FUNCS"
    exit 0
fi

if ! raw=$(aws lambda list-event-source-mappings \
    --event-source-arn "$PRIMARY_ARN" \
    --region "$AWS_REGION" \
    --output json 2>&1); then
    add_issue "Cannot list event source mappings" "list-event-source-mappings failed: $raw" 3 "Verify IAM lambda:ListEventSourceMappings and that the queue ARN matches the attached event sources."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo '[]' > "$OUT_FUNCS"
    echo "$raw"
    exit 0
fi

FUNCS=$(echo "$raw" | jq '[(.EventSourceMappings // [])[] | .FunctionArn | split(":") | if length > 7 then (.[6:] | join(":")) elif length > 6 then .[6] else empty end] | unique')
echo "$FUNCS" | jq '.' > "$OUT_FUNCS"
COUNT=$(echo "$FUNCS" | jq 'length')
echo "Found $COUNT Lambda function(s) with event source mappings for this queue."

if [[ "$COUNT" -eq 0 ]]; then
    add_issue "No Lambda consumers found for this queue" "No event source mappings reference \`$PRIMARY_ARN\`. Consumers may be EC2, ECS, or cross-account." 4 "Check other compute that polls this queue; add CLOUDWATCH_LOG_GROUPS for app log groups."
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Lambda ESM discovery completed. Functions -> $OUT_FUNCS"
