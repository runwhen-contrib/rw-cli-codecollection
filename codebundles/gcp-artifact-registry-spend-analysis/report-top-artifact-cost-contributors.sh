#!/usr/bin/env bash
set -euo pipefail
set -x

# Rank projects and SKUs by artifact storage/transfer spend.

source "$(dirname "$0")/artifact-billing-common.sh"

REPORT_FILE="${REPORT_FILE:-artifact_top_contributors_report.txt}"
ISSUES_FILE="${ISSUES_FILE:-artifact_top_contributors_issues.json}"

init_issues_file "$ISSUES_FILE"

if ! ensure_billing_context; then
    cp "$ISSUES_FILE" artifact_top_contributors_output.json
    cat "$ISSUES_FILE"
    exit 0
fi

lookback_start=$(echo "$DATE_RANGES" | jq -r '.lookback.start')
lookback_end=$(echo "$DATE_RANGES" | jq -r '.lookback.end')
rows=$(query_artifact_cost_rows "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$PROJECT_FILTER")

by_project=$(echo "$rows" | jq '
  group_by(.project_id) |
  map({
    projectId: .[0].project_id,
    projectName: (.[0].project_name // .[0].project_id),
    totalCost: (map(.total_cost | tonumber) | add // 0)
  }) | sort_by(-.totalCost)
')

by_sku=$(echo "$rows" | jq '
  group_by(.sku_description) |
  map({
    sku: .[0].sku_description,
    service: .[0].service_name,
    totalCost: (map(.total_cost | tonumber) | add // 0)
  }) | sort_by(-.totalCost)
')

total_cost=$(echo "$by_project" | jq '[.[].totalCost] | add // 0')

{
    echo "Top Artifact Registry Cost Contributors"
    echo "======================================="
    echo "Total artifact spend: \$$(printf "%.2f" "$total_cost")"
    echo ""
    echo "Top projects:"
    echo "$by_project" | jq -r '.[:10][] | "- \(.projectId): $\(.totalCost | . * 100 | round / 100)"'
    echo ""
    echo "Top SKUs:"
    echo "$by_sku" | jq -r '.[:10][] | "- \(.sku): $\(.totalCost | . * 100 | round / 100)"'
} | tee "$REPORT_FILE"

threshold="${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT:-0}"
if [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$threshold" -gt 0 ]] && (( $(echo "$total_cost > 0" | bc -l) )); then
    while IFS= read -r project_row; do
        [[ -z "$project_row" ]] && continue
        proj_id=$(echo "$project_row" | jq -r '.projectId')
        proj_cost=$(echo "$project_row" | jq -r '.totalCost')
        share=$(echo "scale=2; 100 * $proj_cost / $total_cost" | bc -l)
        if (( $(echo "$share >= $threshold" | bc -l) )); then
            issue=$(jq -n \
                --arg title "Artifact Spend Concentrated in Project \`${proj_id}\`" \
                --argjson severity 3 \
                --arg proj "$proj_id" \
                --arg cost "$proj_cost" \
                --arg share "$share" \
                --arg threshold "$threshold" \
                '{
                  title: $title,
                  severity: $severity,
                  expected: ("No single project should exceed " + $threshold + "% of total artifact spend"),
                  actual: ("Project " + $proj + " accounts for " + $share + "% ($" + $cost + ")"),
                  details: ("Project " + $proj + " represents " + $share + "% of artifact-related spend in the lookback window."),
                  next_steps: "Review artifact inventory and cleanup policies in this project. Cross-reference with gcp-artifact-registry-governance for stale images and missing lifecycle rules."
                }')
            append_issue "$ISSUES_FILE" "$issue"
        fi
    done < <(echo "$by_project" | jq -c '.[]')
fi

while IFS= read -r sku_row; do
    [[ -z "$sku_row" ]] && continue
    sku=$(echo "$sku_row" | jq -r '.sku')
    service=$(echo "$sku_row" | jq -r '.service')
    sku_cost=$(echo "$sku_row" | jq -r '.totalCost')
    if [[ "$service" == *"Container Registry"* ]] || [[ "$sku" == *"Container Registry"* ]]; then
        if (( $(echo "$sku_cost > 0" | bc -l) )); then
            issue=$(jq -n \
                --arg title "Legacy Container Registry Spend Detected" \
                --argjson severity 3 \
                --arg sku "$sku" \
                --arg cost "$sku_cost" \
                '{
                  title: $title,
                  severity: $severity,
                  expected: "Artifact spend should primarily use Artifact Registry rather than legacy GCR",
                  actual: ("Legacy GCR SKU `" + $sku + "` cost $" + $cost + " in lookback window"),
                  details: ("Legacy Container Registry SKU `" + $sku + "` is a top artifact cost contributor."),
                  next_steps: "Plan migration from gcr.io to Artifact Registry and delete unused legacy images after migration."
                }')
            append_issue "$ISSUES_FILE" "$issue"
            break
        fi
    fi
done < <(echo "$by_sku" | jq -c '.[:3][]')

cp "$ISSUES_FILE" artifact_top_contributors_output.json
echo "Top contributors analysis completed."
