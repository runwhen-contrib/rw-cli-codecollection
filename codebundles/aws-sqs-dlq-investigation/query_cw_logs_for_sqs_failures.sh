#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Searches Lambda and optional log groups for errors in the lookback window.
# Reads lambda_esm_functions.json; env LOG_LOOKBACK_MINUTES, CLOUDWATCH_LOG_GROUPS
# Writes query_cw_logs_issues.json
# -----------------------------------------------------------------------------
source "$(dirname "$0")/auth.sh"
auth

: "${AWS_REGION:?Must set AWS_REGION}"

FUNCS_FILE="lambda_esm_functions.json"
OUTPUT_ISSUES="query_cw_logs_issues.json"
LOOKBACK="${LOG_LOOKBACK_MINUTES:-120}"
EXTRA_GROUPS="${CLOUDWATCH_LOG_GROUPS:-}"
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

START_MS=$(( ($(date +%s) - LOOKBACK * 60) * 1000 ))

LOG_GROUPS=()
if [[ -f "$FUNCS_FILE" ]]; then
    while IFS= read -r fn; do
        [[ -z "$fn" ]] && continue
        LOG_GROUPS+=("/aws/lambda/$fn")
    done < <(jq -r '.[]?' "$FUNCS_FILE" 2>/dev/null || true)
fi

if [[ -n "$EXTRA_GROUPS" ]]; then
    IFS=',' read -ra EG <<< "$EXTRA_GROUPS"
    for g in "${EG[@]}"; do
        g=$(echo "$g" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$g" ]] && LOG_GROUPS+=("$g")
    done
fi

if [[ ${#LOG_GROUPS[@]} -eq 0 ]]; then
    add_issue "No log groups to search" "No Lambda mappings were discovered and CLOUDWATCH_LOG_GROUPS is empty. Cannot search CloudWatch logs automatically." 4 "Run Discover Lambda Event Source Mappings or set CLOUDWATCH_LOG_GROUPS to ECS/EC2/app log groups."
    echo "$issues_json" > "$OUTPUT_ISSUES"
    echo "No log groups configured."
    exit 0
fi

FILTER='?ERROR ?Error ?Exception ?REPORT ?Task ?timed'

TOTAL_HITS=0
DETAIL=""
for lg in "${LOG_GROUPS[@]}"; do
    echo "--- Searching $lg ---"
    if ! ev=$(aws logs filter-log-events \
        --log-group-name "$lg" \
        --start-time "$START_MS" \
        --filter-pattern "$FILTER" \
        --limit 50 \
        --region "$AWS_REGION" \
        --output json 2>&1); then
        echo "Skip or error for $lg: $ev"
        continue
    fi
    CNT=$(echo "$ev" | jq '.events | length')
    if [[ "$CNT" -gt 0 ]]; then
        TOTAL_HITS=$((TOTAL_HITS + CNT))
        SNIP=$(echo "$ev" | jq -r '.events[:5][] | .message' | head -c 4000)
        DETAIL="${DETAIL}

### ${lg} (${CNT} matches, sample)
${SNIP}"
        add_issue "Log errors found in \`$lg\`" "Within the last ${LOOKBACK} minutes, filter matched ${CNT} events (showing sample). ${SNIP:0:2000}" 2 "Open CloudWatch Logs Insights for this group and correlate timestamps with DLQ message timing."
    fi
done

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "CloudWatch log scan completed. Total matching groups with hits contributing to issues. Total events (approx): $TOTAL_HITS"
echo "$DETAIL"

# Persist for summarize
jq -n --argjson hits "$TOTAL_HITS" --arg detail "$DETAIL" '{log_scan_total_hits: $hits, log_scan_detail: $detail}' > query_cw_logs_summary.json
