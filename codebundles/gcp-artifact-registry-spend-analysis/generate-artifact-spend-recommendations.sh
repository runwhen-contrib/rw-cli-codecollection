#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Consolidate artifact spend findings into actionable recommendations.
# Reads prior analysis outputs when present; otherwise queries billing export.
# Outputs artifact_spend_recommendations_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="artifact_spend_recommendations_issues.json"
REPORT_FILE="artifact_spend_recommendations_report.txt"
issues_json='[]'

read -r START_DATE END_DATE <<< "$(get_date_range)"

recommendations=()

add_rec() {
    recommendations+=("$1")
}

if [[ -f artifact_spend_analysis_report.json ]]; then
    TOTAL=$(jq '[.[].total_cost | tonumber] | add // 0' artifact_spend_analysis_report.json 2>/dev/null || echo 0)
    TOP_PROJECT=$(jq -r 'group_by(.project_id) | map({id: .[0].project_id, cost: (map(.total_cost|tonumber)|add)}) | sort_by(-.cost) | .[0].id // "unknown"' artifact_spend_analysis_report.json 2>/dev/null || echo "unknown")
    add_rec "Total artifact spend in lookback: \$${TOTAL}. Top project: ${TOP_PROJECT}."
else
    if BILLING_TABLE=$(ensure_billing_access 2>/dev/null); then
        PROJECT_FILTER=$(build_project_filter_sql)
        QUERY="SELECT ROUND(SUM(cost),2) AS total FROM \`${BILLING_TABLE}\` WHERE DATE(usage_start_time) BETWEEN '${START_DATE}' AND '${END_DATE}' AND ${ARTIFACT_SKU_FILTER} ${PROJECT_FILTER}"
        TOTAL=$(run_bq_query_json "$BILLING_TABLE" "$QUERY" 1 | jq -r '.[0].total // 0' 2>/dev/null || echo 0)
        add_rec "Estimated artifact spend (\$${TOTAL}) from billing export."
    fi
fi

if [[ -f top_artifact_cost_contributors_report.txt ]]; then
    if grep -qi "Legacy Container Registry" top_artifact_cost_contributors_report.txt 2>/dev/null || \
       jq -e '[.[] | select(.sku_description | test("container registry|gcr"; "i"))] | length > 0' artifact_spend_analysis_report.json &>/dev/null; then
        add_rec "Migrate legacy gcr.io storage to Artifact Registry and delete unused GCR buckets."
    fi
fi

if [[ -f artifact_spend_mom_report.txt ]]; then
    if grep -qi "growth" artifact_spend_mom_report.txt 2>/dev/null; then
        add_rec "Enable Artifact Registry cleanup policies on repositories with rising storage MoM."
    fi
fi

# Standard recommendations
add_rec "Enable cleanup policies to delete untagged images older than 30-90 days."
add_rec "Deduplicate tags and remove stale version pins across CI pipelines."
add_rec "Right-size vulnerability scanning: disable scanning on dev repos or use on-push only."
add_rec "Cross-reference high-cost projects with gcp-artifact-registry-governance inventory."

{
    echo "Artifact Registry Spend Optimization Summary"
    echo "Scope: ${GCP_PROJECT_IDS:-auto-discovered projects}"
    echo ""
    for rec in "${recommendations[@]}"; do
        echo "  - $rec"
    done
} > "$REPORT_FILE"

# High spend projects for follow-up
if [[ -f artifact_spend_analysis_report.json ]]; then
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        pid=$(echo "$row" | jq -r '.id')
        pcost=$(echo "$row" | jq -r '.cost')
        if (( $(echo "$pcost >= 100" | bc -l 2>/dev/null || echo 0) )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Artifact Spend Optimization Follow-up: \`${pid}\`" \
                --arg details "Project ${pid} has \$${pcost} in artifact-related spend. Review cleanup policies and stale images." \
                --arg severity "4" \
                --arg next_steps "Run gcp-artifact-registry-governance on ${pid}. Enable cleanup policies and retire duplicate tags." \
                '. += [{
                   "title": $title,
                   "severity": ($severity | tonumber),
                   "expected": "Artifact spend should align with actively used images and repositories",
                   "actual": $details,
                   "details": $details,
                   "next_steps": $next_steps
                 }]')
        fi
    done < <(jq -c 'group_by(.project_id) | map({id: .[0].project_id, cost: (map(.total_cost|tonumber)|add)}) | sort_by(-.cost) | .[:5][]' artifact_spend_analysis_report.json 2>/dev/null || true)
fi

if [[ $(echo "$issues_json" | jq 'length') -eq 0 ]]; then
    rec_text=$(printf '%s\n' "${recommendations[@]}")
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Artifact Registry Spend Optimization Recommendations" \
        --arg details "$rec_text" \
        --arg severity "4" \
        --arg next_steps "Apply cleanup policies, migrate legacy GCR, and coordinate with gcp-artifact-registry-governance on high-spend projects." \
        '. += [{
           "title": $title,
           "severity": ($severity | tonumber),
           "expected": "Artifact spend should be optimized with cleanup policies and legacy GCR retirement",
           "actual": "Consolidated recommendations generated from billing analysis",
           "details": $details,
           "next_steps": $next_steps
         }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
cat "$REPORT_FILE"
