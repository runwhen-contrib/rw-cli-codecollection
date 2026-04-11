#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists Lambda event source mappings for primary queue ARNs.
# Writes: discover_lambda_issues.json, lambda_consumers.json
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Must set AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

auth

OUTPUT_FILE="discover_lambda_issues.json"
CONSUMERS_FILE="lambda_consumers.json"
CONTEXT_FILE="sqs_investigation_context.json"
issues_json='[]'

if [[ ! -f "$CONTEXT_FILE" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing investigation context" \
        --arg details "Expected $CONTEXT_FILE from the redrive/DLQ depth task." \
        --argjson severity 4 \
        --arg next_steps "Run Check SQS Redrive Policy and DLQ Depth first." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo '{"functions":[],"mappings":[]}' > "$CONSUMERS_FILE"
    exit 0
fi

all_mappings='[]'

while IFS= read -r primary_arn; do
    [[ -z "$primary_arn" ]] && continue
    echo "Discovering Lambda mappings for $primary_arn"
    resp=$(aws lambda list-event-source-mappings \
        --region "$AWS_REGION" \
        --event-source-arn "$primary_arn" \
        --output json 2>/dev/null) || resp="{}"
    chunk=$(echo "$resp" | jq '[.EventSourceMappings[]?]')
    all_mappings=$(echo "$all_mappings" | jq --argjson c "$chunk" '. + $c')
done < <(jq -r '.queues[]? | .primary_arn // empty' "$CONTEXT_FILE" | sort -u)

fnames=$(echo "$all_mappings" | jq '[.[].FunctionArn] | unique')
echo "$all_mappings" | jq --argjson f "$fnames" '{ "mappings": ., "functions": $f }' > "$CONSUMERS_FILE"

map_count=$(echo "$all_mappings" | jq 'length')
if [[ "$map_count" -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Lambda event source mappings for target queues" \
        --arg details "Consumers may be ECS/EKS, EC2, or cross-account. Use EXTRA_LOG_GROUP_NAMES in the log task or identify workers manually." \
        --argjson severity 4 \
        --arg next_steps "Set EXTRA_LOG_GROUP_NAMES to CloudWatch log groups for non-Lambda processors, or confirm queue consumers in AWS Console." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Lambda consumers:"
jq . "$CONSUMERS_FILE"
jq . "$OUTPUT_FILE"
