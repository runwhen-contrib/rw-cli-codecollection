#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Consolidates state and log scan into a human report and cross-cutting issues.
# Writes summarize_sqs_dlq_findings_issues.json
# -----------------------------------------------------------------------------
source "$(dirname "$0")/auth.sh"
auth

STATE_FILE="sqs_dlq_state.json"
OUTPUT_ISSUES="summarize_sqs_dlq_findings_issues.json"
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

DLQ_MSGS="0"
PRIMARY="unknown"
if [[ -f "$STATE_FILE" ]]; then
    DLQ_MSGS=$(jq -r '.dlq_approximate_messages // 0' "$STATE_FILE")
    PRIMARY=$(jq -r '.primary_queue_arn // "unknown"' "$STATE_FILE")
fi

LOG_HITS=0
if [[ -f "query_cw_logs_summary.json" ]]; then
    LOG_HITS=$(jq -r '.log_scan_total_hits // 0' "query_cw_logs_summary.json" | tr -d '\n')
fi

SUMMARY="## SQS DLQ triage summary

- **Primary queue**: ${PRIMARY}
- **DLQ approximate messages (last read)**: ${DLQ_MSGS}
- **Log filter hits (recent scan)**: ${LOG_HITS}

### Recommended next steps
1. If DLQ has messages: identify poison messages, fix consumer code or timeouts, then replay or purge after validation.
2. If Lambda logs show errors: deploy a fix and consider adjusting visibility timeout or partial batch failure (including FIFO).
3. If no Lambda mappings were found: add CLOUDWATCH_LOG_GROUPS for ECS/EC2 or other consumers.

"

echo "$SUMMARY"

if [[ "$DLQ_MSGS" =~ ^[0-9]+$ ]] && [[ "$DLQ_MSGS" -gt 0 ]] && [[ "${LOG_HITS:-0}" =~ ^[0-9]+$ ]] && [[ "$LOG_HITS" -gt 0 ]]; then
    add_issue "DLQ has messages and logs show processing failures" "Approximate DLQ messages: ${DLQ_MSGS}. CloudWatch scan recorded ${LOG_HITS} matching log events across searched groups." 2 "Prioritize fixing the consumer errors shown in logs, then replay messages from the DLQ after verification."
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Summary issues written to $OUTPUT_ISSUES"
