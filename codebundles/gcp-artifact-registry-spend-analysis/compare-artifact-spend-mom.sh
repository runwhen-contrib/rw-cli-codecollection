#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Compare artifact-related costs across the last three complete calendar months.
# Outputs artifact_spend_mom_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="artifact_spend_mom_issues.json"
REPORT_FILE="artifact_spend_mom_report.txt"
GROWTH_THRESHOLD="${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT:-25}"
issues_json='[]'

if ! BILLING_TABLE=$(ensure_billing_access); then
    cat "$OUTPUT_FILE"
    exit 0
fi

PROJECT_FILTER=$(build_project_filter_sql)

# Last 3 complete calendar months
M3_START=$(date -u -d "$(date -u +%Y-%m-01) -3 months" +%Y-%m-%d 2>/dev/null || date -u -v-3m -v1d +%Y-%m-%d)
M3_END=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)

QUERY="
SELECT
  FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS month,
  project.id AS project_id,
  ROUND(SUM(cost), 4) AS total_cost,
  ROUND(SUM(IF(LOWER(sku.description) LIKE '%storage%' OR LOWER(sku.description) LIKE '%stored%', cost, 0)), 4) AS storage_cost,
  ROUND(SUM(IF(LOWER(sku.description) LIKE '%egress%' OR LOWER(sku.description) LIKE '%transfer%' OR LOWER(sku.description) LIKE '%network%', cost, 0)), 4) AS transfer_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${M3_START}' AND '${M3_END}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY month, project_id
ORDER BY month, total_cost DESC
"

if ! RESULT=$(run_bq_query_json "$BILLING_TABLE" "$QUERY" 50000); then
    write_access_issue "Cannot Compare Artifact Spend Month-over-Month" "MoM query failed." "$OUTPUT_FILE"
    exit 0
fi

MONTHS=($(echo "$RESULT" | jq -r '[.[].month] | unique | sort | .[]'))
MONTH_COUNT=${#MONTHS[@]}

{
    echo "Artifact Registry Month-over-Month Comparison"
    echo "Months: ${MONTHS[*]:-none}"
    echo "Growth threshold: ${GROWTH_THRESHOLD}%"
    echo ""
    for m in "${MONTHS[@]}"; do
        month_total=$(echo "$RESULT" | jq --arg m "$m" '[.[] | select(.month == $m) | .total_cost | tonumber] | add // 0')
        echo "${m}: \$${month_total}"
    done
} > "$REPORT_FILE"

if [[ "$MONTH_COUNT" -lt 2 ]]; then
    echo "$issues_json" > "$OUTPUT_FILE"
    cat "$REPORT_FILE"
    exit 0
fi

PREV_MONTH="${MONTHS[$((MONTH_COUNT - 2))]}"
CURR_MONTH="${MONTHS[$((MONTH_COUNT - 1))]}"

# Org-wide MoM
PREV_TOTAL=$(echo "$RESULT" | jq --arg m "$PREV_MONTH" '[.[] | select(.month == $m) | .total_cost | tonumber] | add // 0')
CURR_TOTAL=$(echo "$RESULT" | jq --arg m "$CURR_MONTH" '[.[] | select(.month == $m) | .total_cost | tonumber] | add // 0')

if (( $(echo "$PREV_TOTAL > 0" | bc -l) )); then
    GROWTH=$(echo "scale=1; 100 * ($CURR_TOTAL - $PREV_TOTAL) / $PREV_TOTAL" | bc -l)
    if (( $(echo "$GROWTH >= $GROWTH_THRESHOLD" | bc -l) )); then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Artifact Spend MoM Growth Exceeds ${GROWTH_THRESHOLD}%" \
            --arg details "Total artifact spend grew ${GROWTH}% from ${PREV_MONTH} (\$${PREV_TOTAL}) to ${CURR_MONTH} (\$${CURR_TOTAL})." \
            --arg severity "2" \
            --arg next_steps "Investigate top projects and SKUs. Cross-reference with gcp-artifact-registry-governance for stale images." \
            '. += [{
               "title": $title,
               "severity": ($severity | tonumber),
               "expected": "Artifact spend growth should stay below '"${GROWTH_THRESHOLD}"'% month-over-month",
               "actual": $details,
               "details": $details,
               "next_steps": $next_steps
             }]')
    fi
fi

# Storage growth without transfer growth (per project)
PROJECTS=$(echo "$RESULT" | jq -r '[.[].project_id] | unique | .[]')
while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    prev_storage=$(echo "$RESULT" | jq --arg m "$PREV_MONTH" --arg p "$proj" '[.[] | select(.month == $m and .project_id == $p) | .storage_cost | tonumber] | add // 0')
    curr_storage=$(echo "$RESULT" | jq --arg m "$CURR_MONTH" --arg p "$proj" '[.[] | select(.month == $m and .project_id == $p) | .storage_cost | tonumber] | add // 0')
    prev_transfer=$(echo "$RESULT" | jq --arg m "$PREV_MONTH" --arg p "$proj" '[.[] | select(.month == $m and .project_id == $p) | .transfer_cost | tonumber] | add // 0')
    curr_transfer=$(echo "$RESULT" | jq --arg m "$CURR_MONTH" --arg p "$proj" '[.[] | select(.month == $m and .project_id == $p) | .transfer_cost | tonumber] | add // 0')

    if (( $(echo "$prev_storage > 1 && $curr_storage > 0" | bc -l) )); then
        storage_growth=$(echo "scale=1; 100 * ($curr_storage - $prev_storage) / $prev_storage" | bc -l)
        transfer_growth=0
        if (( $(echo "$prev_transfer > 0.01" | bc -l) )); then
            transfer_growth=$(echo "scale=1; 100 * ($curr_transfer - $prev_transfer) / $prev_transfer" | bc -l)
        fi
        if (( $(echo "$storage_growth >= $GROWTH_THRESHOLD && $transfer_growth < 10" | bc -l) )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Rising Artifact Storage Without Pull Activity: \`${proj}\`" \
                --arg details "Storage cost grew ${storage_growth}% MoM while transfer grew ${transfer_growth}% for project ${proj}." \
                --arg severity "2" \
                --arg next_steps "Review stale images and enable cleanup policies. Run gcp-artifact-registry-governance inventory." \
                '. += [{
                   "title": $title,
                   "severity": ($severity | tonumber),
                   "expected": "Storage cost increases should correlate with artifact pull/transfer activity",
                   "actual": $details,
                   "details": $details,
                   "next_steps": $next_steps
                 }]')
        fi
    fi
done <<< "$PROJECTS"

echo "$issues_json" > "$OUTPUT_FILE"
cat "$REPORT_FILE"
