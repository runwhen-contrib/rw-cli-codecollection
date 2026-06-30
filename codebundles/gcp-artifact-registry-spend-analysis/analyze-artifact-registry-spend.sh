#!/usr/bin/env bash
set -euo pipefail
set -x

# Analyze Artifact Registry and legacy GCR spend by project and SKU with rollups.

source "$(dirname "$0")/artifact-billing-common.sh"

REPORT_FILE="${REPORT_FILE:-artifact_spend_report.txt}"
JSON_FILE="${JSON_FILE:-artifact_spend_report.json}"
ISSUES_FILE="${ISSUES_FILE:-artifact_spend_analysis_issues.json}"

init_issues_file "$ISSUES_FILE"

if ! ensure_billing_context; then
    cat "$ISSUES_FILE"
    cp "$ISSUES_FILE" artifact_spend_analysis_output.json
    exit 0
fi

lookback_start=$(echo "$DATE_RANGES" | jq -r '.lookback.start')
lookback_end=$(echo "$DATE_RANGES" | jq -r '.lookback.end')
week_start=$(echo "$DATE_RANGES" | jq -r '.weekly.start')
week_end=$(echo "$DATE_RANGES" | jq -r '.weekly.end')
month_start=$(echo "$DATE_RANGES" | jq -r '.monthly.start')
month_end=$(echo "$DATE_RANGES" | jq -r '.monthly.end')

rows=$(query_artifact_cost_rows "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$PROJECT_FILTER")

if [[ "$(echo "$rows" | jq 'length')" -eq 0 ]]; then
    log "No artifact-related billing rows found for lookback window"
fi

aggregated=$(echo "$rows" | jq --argjson ranges "$DATE_RANGES" '
  group_by(.project_id + "|" + .sku_description) |
  map({
    projectId: .[0].project_id,
    projectName: (.[0].project_name // .[0].project_id),
    service: .[0].service_name,
    sku: .[0].sku_description,
    totalCost: (map(.total_cost | tonumber) | add // 0),
    daily: ($ranges.daily | map(. as $date | {
      date: $date,
      cost: ([.[] | select(.usage_date == $date) | .total_cost | tonumber] | add // 0)
    })),
    weeklyCost: ([.[] | select(.usage_date >= $ranges.weekly.start and .usage_date <= $ranges.weekly.end) | .total_cost | tonumber] | add // 0),
    monthlyCost: ([.[] | select(.usage_date >= $ranges.monthly.start and .usage_date <= $ranges.monthly.end) | .total_cost | tonumber] | add // 0)
  }) | sort_by(-.totalCost)
')

total_cost=$(echo "$aggregated" | jq '[.[].totalCost] | add // 0')

{
    echo "GCP Artifact Registry Spend Analysis"
    echo "===================================="
    echo "Projects: ${GCP_PROJECT_IDS:-auto-discovered}"
    echo "Lookback: ${lookback_start} to ${lookback_end} (${LOOKBACK_DAYS} days)"
    echo "Total artifact spend: \$$(printf "%.2f" "$total_cost")"
    echo ""
    echo "Top project/SKU contributors:"
    echo "$aggregated" | jq -r '.[:15][] | "- \(.projectId) | \(.sku): $\(.totalCost | . * 100 | round / 100)"'
    echo ""
    echo "Rollups:"
    echo "  Weekly (${week_start} to ${week_end}): \$$(echo "$aggregated" | jq '[.[].weeklyCost] | add // 0')"
    echo "  Monthly (${month_start} to ${month_end}): \$$(echo "$aggregated" | jq '[.[].monthlyCost] | add // 0')"
} | tee "$REPORT_FILE"

jq -n \
    --argjson rows "$aggregated" \
    --argjson ranges "$DATE_RANGES" \
    --arg total "$total_cost" \
    '{
      reportType: "artifact-registry-spend-analysis",
      totalCost: ($total | tonumber),
      currency: "USD",
      dateRanges: $ranges,
      contributors: $rows
    }' > "$JSON_FILE"

cp "$ISSUES_FILE" artifact_spend_analysis_output.json
echo "Analysis completed. Report: $REPORT_FILE"
