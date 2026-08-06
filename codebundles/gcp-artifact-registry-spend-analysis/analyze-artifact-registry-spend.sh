#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: (optional) GCP_PROJECT_IDS, GCP_BILLING_EXPORT_TABLE
# OPTIONAL: COST_ANALYSIS_LOOKBACK_DAYS, OUTPUT_FORMAT
#
# Query BigQuery billing export for Artifact Registry and legacy GCR SKUs.
# Produces per-project, per-SKU totals with daily/weekly/monthly rollups.
# Outputs artifact_spend_analysis_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="artifact_spend_analysis_issues.json"
REPORT_FILE="artifact_spend_analysis_report.txt"
JSON_FILE="artifact_spend_analysis_report.json"
CSV_FILE="artifact_spend_analysis_report.csv"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"
issues_json='[]'

read -r START_DATE END_DATE <<< "$(get_date_range)"
LOOKBACK=$(get_lookback_days)

echo "Analyzing Artifact Registry spend from ${START_DATE} to ${END_DATE} (${LOOKBACK}-day lookback)"

if ! BILLING_TABLE=$(ensure_billing_access); then
    cat artifact_spend_analysis_issues.json
    exit 0
fi

PROJECT_FILTER=$(build_project_filter_sql)

QUERY="
SELECT
  project.id AS project_id,
  project.name AS project_name,
  sku.description AS sku_description,
  ROUND(SUM(cost), 4) AS total_cost,
  ROUND(SUM(IF(DATE(usage_start_time) >= DATE_SUB('${END_DATE}', INTERVAL 7 DAY), cost, 0)), 4) AS weekly_cost,
  ROUND(SUM(IF(DATE(usage_start_time) >= DATE_SUB('${END_DATE}', INTERVAL 30 DAY), cost, 0)), 4) AS monthly_cost,
  ROUND(SUM(IF(DATE(usage_start_time) >= DATE_SUB('${END_DATE}', INTERVAL ${LOOKBACK} DAY), cost, 0)), 4) AS lookback_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${START_DATE}' AND '${END_DATE}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY project_id, project_name, sku_description
HAVING total_cost > 0
ORDER BY total_cost DESC
"

if ! RESULT=$(run_bq_query_json "$BILLING_TABLE" "$QUERY" 50000); then
    write_access_issue "Cannot Query Artifact Registry Spend for \`${GCP_PROJECT_IDS:-all projects}\`" "BigQuery query for artifact spend failed." "$OUTPUT_FILE"
    exit 0
fi

ROW_COUNT=$(echo "$RESULT" | jq 'length')
TOTAL_COST=$(echo "$RESULT" | jq '[.[].total_cost | tonumber] | add // 0')

{
    echo "GCP Artifact Registry Spend Analysis"
    echo "Period: ${START_DATE} to ${END_DATE}"
    echo "Total artifact-related spend: \$${TOTAL_COST}"
    echo "Rows (project x SKU): ${ROW_COUNT}"
    echo ""
    echo "Top contributors:"
    echo "$RESULT" | jq -r '.[:15][] | "\(.project_id)\t\(.sku_description)\t$\(.total_cost)"' 2>/dev/null || true
} > "$REPORT_FILE"

echo "$RESULT" | jq '.' > "$JSON_FILE"

if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
    echo "project_id,project_name,sku_description,total_cost,weekly_cost,monthly_cost,lookback_cost" > "$CSV_FILE"
    echo "$RESULT" | jq -r '.[] | [.project_id, .project_name, .sku_description, .total_cost, .weekly_cost, .monthly_cost, .lookback_cost] | @csv' >> "$CSV_FILE"
fi

if [[ "$ROW_COUNT" -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Artifact Registry Spend Found for \`${GCP_PROJECT_IDS:-configured scope}\`" \
        --arg details "No billing rows matched Artifact Registry or legacy Container Registry SKUs in the lookback window." \
        --arg severity "3" \
        --arg next_steps "Confirm projects use Artifact Registry/GCR and billing export includes recent data. Run gcp-artifact-registry-governance for inventory." \
        '. += [{
           "title": $title,
           "severity": ($severity | tonumber),
           "expected": "Projects with active artifact storage should appear in billing export",
           "actual": "Zero artifact-related SKU costs in the last '"${LOOKBACK}"' days",
           "details": $details,
           "next_steps": $next_steps
         }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Report: $REPORT_FILE"
cat "$REPORT_FILE"
