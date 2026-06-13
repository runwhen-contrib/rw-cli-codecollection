#!/usr/bin/env bash
# Resolves Lambda event source mappings for source queues and searches CloudWatch Logs for errors in the lookback window.
# Writes JSON issues to dlq_lambda_logs_issues.json (jq).

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/auth.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/sqs_dlq_common.sh"

auth

: "${AWS_REGION:?Must set AWS_REGION}"

OUTPUT_FILE="dlq_lambda_logs_issues.json"
LOOKBACK="${CLOUDWATCH_LOG_LOOKBACK_MINUTES:-30}"
issues_json='[]'
start_ms=$(($(date +%s) - LOOKBACK * 60))000

echo "=== Lambda consumer logs (lookback ${LOOKBACK} minutes, start_ms=${start_ms}) ==="

SOURCE_URLS=()
if [[ -n "${SQS_QUEUE_URL:-}" || -n "${SQS_QUEUE_URLS:-}" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(rw_sqs_collect_source_urls)
else
    prefix="${SQS_QUEUE_NAME_PREFIX:-}"
    raw=$(aws sqs list-queues --region "$AWS_REGION" ${prefix:+--queue-name-prefix "$prefix"} --output json 2>/dev/null || echo '{}')
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(echo "$raw" | jq -r '.QueueUrls[]? // empty')
fi

if [[ ${#SOURCE_URLS[@]} -eq 0 ]]; then
    echo '[]' > "$OUTPUT_FILE"
    exit 0
fi

for src in "${SOURCE_URLS[@]}"; do
    [[ -z "$src" ]] && continue
    qarn=$(aws sqs get-queue-attributes --queue-url "$src" --attribute-names QueueArn --output json 2>/dev/null | jq -r '.Attributes.QueueArn // empty')
    [[ -z "$qarn" ]] && continue

    dlq_depth=0
    if resolved=$(rw_sqs_resolve_dlq_url "$src"); then
        dlq_url="${resolved##*|}"
        d=$(rw_sqs_queue_depth "$dlq_url")
        [[ "$d" =~ ^[0-9]+$ ]] && dlq_depth="$d"
    fi

    mappings_json=$(aws lambda list-event-source-mappings --event-source-arn "$qarn" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"EventSourceMappings":[]}')
    map_count=$(echo "$mappings_json" | jq '.EventSourceMappings | length // 0')

    if [[ "$map_count" -eq 0 ]]; then
        if [[ "$dlq_depth" -gt 0 ]]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "No Lambda event source mapping for queue with DLQ traffic" \
                --arg details "Queue ${src} has no Lambda event source mappings but DLQ approximate depth is ${dlq_depth}. Consumer may be ECS, EC2, or another service—correlate using that platform's logs." \
                --argjson severity 3 \
                --arg next_steps "Find the active consumer for this queue (non-Lambda), inspect its logs and metrics, and fix processing failures. If the consumer should be Lambda, create or fix the event source mapping." \
                '. += [{
                  "title": $title,
                  "details": $details,
                  "severity": $severity,
                  "next_steps": $next_steps
                }]')
        fi
        continue
    fi

    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        fn_arn=$(echo "$row" | jq -r '.FunctionArn // empty')
        [[ -z "$fn_arn" ]] && continue
        fn_name="${fn_arn#*:function:}"

        log_group="/aws/lambda/${fn_name}"
        lg_name=$(aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$AWS_REGION" --output json 2>/dev/null | jq -r '.logGroups[0].logGroupName // empty')
        if [[ -z "$lg_name" ]]; then
            echo "Log group not found for ${log_group}"
            continue
        fi

        fe=$(aws logs filter-log-events \
            --log-group-name "$lg_name" \
            --start-time "$start_ms" \
            --filter-pattern "?ERROR ?Error ?Task ?timed" \
            --limit 50 \
            --region "$AWS_REGION" \
            --output json 2>/dev/null || echo '{}')

        ev_count=$(echo "$fe" | jq '.events | length // 0')
        if [[ "$ev_count" -eq 0 ]]; then
            echo "No matching log events for ${fn_name} in window."
            continue
        fi

        details_safe=$(echo "$fe" | jq -c '{matchingEvents: (.events | length), sample: [.events[]? | {timestamp: .timestamp, message: .message}] | .[0:5]}')

        issues_json=$(echo "$issues_json" | jq \
            --arg title "Lambda \`${fn_name}\` logs show errors overlapping DLQ window" \
            --arg details "$details_safe" \
            --argjson severity 3 \
            --arg next_steps "Open CloudWatch Logs for ${lg_name}, inspect the stack traces, fix the Lambda code or configuration (timeout, memory, permissions), then redrive DLQ messages after verification." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
    done < <(echo "$mappings_json" | jq -c '.EventSourceMappings[]? // empty')
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
exit 0
