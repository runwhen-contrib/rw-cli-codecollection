#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Fetches recent ERROR / timeout / runtime exception lines from Lambda log groups.
# Writes: fetch_lambda_logs_issues.json
# Env: CLOUDWATCH_LOG_LOOKBACK_MINUTES, EXTRA_LOG_GROUP_NAMES (comma-separated)
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Must set AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

auth

OUTPUT_FILE="fetch_lambda_logs_issues.json"
CONSUMERS_FILE="lambda_consumers.json"
LOOKBACK_MIN="${CLOUDWATCH_LOG_LOOKBACK_MINUTES:-60}"
issues_json='[]'

START_MS=$(($(date +%s) * 1000 - LOOKBACK_MIN * 60 * 1000))

log_groups=()

if [[ -f "$CONSUMERS_FILE" ]]; then
    while IFS= read -r arn; do
        [[ -z "$arn" || "$arn" == "null" ]] && continue
        fname=$(echo "$arn" | awk -F: '{print $NF}')
        log_groups+=("/aws/lambda/$fname")
    done < <(jq -r '.functions[]?' "$CONSUMERS_FILE" 2>/dev/null || true)
fi

if [[ -n "${EXTRA_LOG_GROUP_NAMES:-}" ]]; then
    IFS=',' read -ra extra <<< "${EXTRA_LOG_GROUP_NAMES}"
    for g in "${extra[@]}"; do
        g=$(echo "$g" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$g" ]] && log_groups+=("$g")
    done
fi

readarray -t log_groups < <(printf '%s\n' "${log_groups[@]}" | sort -u)
if [[ ${#log_groups[@]} -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Lambda functions or log groups to search" \
        --arg details "No consumers were discovered and EXTRA_LOG_GROUP_NAMES is empty." \
        --argjson severity 4 \
        --arg next_steps "Run Discover Lambda Consumers first, or set EXTRA_LOG_GROUP_NAMES for ECS/EKS or other processors." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    jq . "$OUTPUT_FILE"
    exit 0
fi

report='[]'
# Filter pattern: match ERROR, Task timed out, or Runtime exceptions (broad)
FILTER='ERROR ?Task ?timed ?out ?Runtime'

for lg in "${log_groups[@]}"; do
    echo "Scanning log group: $lg"
    evts=$(aws logs filter-log-events \
        --region "$AWS_REGION" \
        --log-group-name "$lg" \
        --filter-pattern "$FILTER" \
        --start-time "$START_MS" \
        --limit 50 \
        --output json 2>/dev/null) || evts='{"events":[]}'

    cnt=$(echo "$evts" | jq '[.events[]?] | length')
    if [[ "$cnt" -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Processor errors in logs for \`$lg\`" \
            --arg details "$(echo "$evts" | jq -c '{event_count: (.events|length), sample_messages: [.events[0:3][]?.message]}')" \
            --argjson severity 2 \
            --arg next_steps "Open CloudWatch Logs for this group, fix application errors, then redrive DLQ messages if appropriate." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
    fi
    report=$(echo "$report" | jq \
        --arg lg "$lg" \
        --argjson cnt "$cnt" \
        '. += [{ "log_group": $lg, "matching_events": $cnt }]')
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Log scan summary:"
echo "$report" | jq .
jq . "$OUTPUT_FILE"
