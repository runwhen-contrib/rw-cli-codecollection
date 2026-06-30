#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Rank projects and SKUs by artifact storage and transfer spend.
# Raises issues when share or absolute thresholds are exceeded.
# Outputs top_artifact_cost_contributors_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="top_artifact_cost_contributors_issues.json"
REPORT_FILE="top_artifact_cost_contributors_report.txt"
THRESHOLD_PERCENT="${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT:-20}"
issues_json='[]'

read -r START_DATE END_DATE <<< "$(get_date_range)"

echo "Reporting top Artifact Registry cost contributors (${START_DATE} to ${END_DATE})"

if ! BILLING_TABLE=$(ensure_billing_access); then
    cat "$OUTPUT_FILE"
    exit 0
fi

PROJECT_FILTER=$(build_project_filter_sql)

PROJECT_QUERY="
SELECT project.id AS project_id, project.name AS project_name, ROUND(SUM(cost), 4) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${START_DATE}' AND '${END_DATE}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY project_id, project_name
HAVING total_cost > 0
ORDER BY total_cost DESC
"

SKU_QUERY="
SELECT sku.description AS sku_description, ROUND(SUM(cost), 4) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${START_DATE}' AND '${END_DATE}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY sku_description
HAVING total_cost > 0
ORDER BY total_cost DESC
"

if ! PROJECT_RESULT=$(run_bq_query_json "$BILLING_TABLE" "$PROJECT_QUERY" 1000); then
    write_access_issue "Cannot Rank Artifact Cost Contributors" "Project ranking query failed." "$OUTPUT_FILE"
    exit 0
fi

if ! SKU_RESULT=$(run_bq_query_json "$BILLING_TABLE" "$SKU_QUERY" 500); then
    write_access_issue "Cannot Rank Artifact SKU Contributors" "SKU ranking query failed." "$OUTPUT_FILE"
    exit 0
fi

TOTAL=$(echo "$PROJECT_RESULT" | jq '[.[].total_cost | tonumber] | add // 0')
THRESH=$(echo "$THRESHOLD_PERCENT" | awk '{print $1+0}')

{
    echo "Top Artifact Registry Cost Contributors"
    echo "Total spend: \$${TOTAL}"
    echo ""
    echo "By project:"
    echo "$PROJECT_RESULT" | jq -r '.[] | "  \(.project_id): $\(.total_cost)"'
    echo ""
    echo "By SKU:"
    echo "$SKU_RESULT" | jq -r '.[] | "  \(.sku_description): $\(.total_cost)"'
} > "$REPORT_FILE"

if (( $(echo "$TOTAL > 0" | bc -l) )) && (( $(echo "$THRESH > 0" | bc -l) )); then
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        proj_id=$(echo "$row" | jq -r '.project_id')
        proj_name=$(echo "$row" | jq -r '.project_name')
        cost=$(echo "$row" | jq -r '.total_cost')
        pct=$(echo "scale=1; 100 * $cost / $TOTAL" | bc -l)
        if (( $(echo "$pct >= $THRESH" | bc -l) )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Project \`${proj_id}\` Exceeds ${THRESH}% of Artifact Spend" \
                --arg details "Project ${proj_name} (${proj_id}) accounts for ${pct}% of artifact spend (\$${cost} of \$${TOTAL})." \
                --arg severity "3" \
                --arg next_steps "Review artifact inventory with gcp-artifact-registry-governance. Enable cleanup policies and retire unused images." \
                --arg expected "No single project should exceed ${THRESH}% of total artifact spend without justification" \
                --arg actual "${pct}% share (\$${cost})" \
                '. += [{
                   "title": $title,
                   "severity": ($severity | tonumber),
                   "expected": $expected,
                   "actual": $actual,
                   "details": $details,
                   "next_steps": $next_steps
                 }]')
        fi
    done < <(echo "$PROJECT_RESULT" | jq -c '.[]')
fi

# Legacy GCR dominant spend
LEGACY_COST=$(echo "$SKU_RESULT" | jq '[.[] | select(.sku_description | test("container registry|gcr"; "i")) | .total_cost | tonumber] | add // 0')
if (( $(echo "$TOTAL > 0 && $LEGACY_COST > 0" | bc -l) )); then
    LEGACY_PCT=$(echo "scale=1; 100 * $LEGACY_COST / $TOTAL" | bc -l)
    if (( $(echo "$LEGACY_PCT >= 30" | bc -l) )); then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Legacy Container Registry Dominates Artifact Spend" \
            --arg details "Legacy GCR SKUs account for ${LEGACY_PCT}% (\$${LEGACY_COST}) of artifact-related spend." \
            --arg severity "3" \
            --arg next_steps "Migrate remaining gcr.io images to Artifact Registry and disable legacy GCR buckets to reduce storage costs." \
            '. += [{
               "title": $title,
               "severity": ($severity | tonumber),
               "expected": "Artifact spend should primarily use Artifact Registry rather than legacy GCR",
               "actual": $details,
               "details": $details,
               "next_steps": $next_steps
             }]')
    fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
cat "$REPORT_FILE"
