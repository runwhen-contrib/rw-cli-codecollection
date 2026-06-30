#!/usr/bin/env bash
set -euo pipefail
set -x

# Compare artifact spend across the last three complete calendar months.

source "$(dirname "$0")/artifact-billing-common.sh"

REPORT_FILE="${REPORT_FILE:-artifact_mom_report.txt}"
ISSUES_FILE="${ISSUES_FILE:-artifact_mom_issues.json}"

init_issues_file "$ISSUES_FILE"

if ! ensure_billing_context; then
    cp "$ISSUES_FILE" artifact_mom_output.json
    cat "$ISSUES_FILE"
    exit 0
fi

months=$(get_last_three_complete_months)
m1_start=$(echo "$months" | jq -r '.month1.start')
m1_end=$(echo "$months" | jq -r '.month1.end')
m2_start=$(echo "$months" | jq -r '.month2.start')
m2_end=$(echo "$months" | jq -r '.month2.end')
m3_start=$(echo "$months" | jq -r '.month3.start')
m3_end=$(echo "$months" | jq -r '.month3.end')

query_month_total() {
    local start="$1"
    local end="$2"
    local extra_filter="${3:-}"
    local sku_filter
    sku_filter=$(artifact_sku_filter_sql)
    local query="
SELECT
  SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) >= '${start}'
  AND DATE(usage_start_time) <= '${end}'
  AND ${sku_filter}
  ${extra_filter}
  ${PROJECT_FILTER}
"
    run_bq_json_query "$BILLING_TABLE" "$query" | jq -r '.[0].total_cost // 0'
}

storage_filter="AND $(artifact_storage_sku_filter_sql)"
transfer_filter="AND $(artifact_transfer_sku_filter_sql)"

m1_total=$(query_month_total "$m1_start" "$m1_end")
m2_total=$(query_month_total "$m2_start" "$m2_end")
m3_total=$(query_month_total "$m3_start" "$m3_end")

m1_storage=$(query_month_total "$m1_start" "$m1_end" "$storage_filter")
m2_storage=$(query_month_total "$m2_start" "$m2_end" "$storage_filter")
m1_transfer=$(query_month_total "$m1_start" "$m1_end" "$transfer_filter")
m2_transfer=$(query_month_total "$m2_start" "$m2_end" "$transfer_filter")

mom_pct=0
if (( $(echo "$m2_total > 0" | bc -l) )); then
    mom_pct=$(echo "scale=2; (($m1_total - $m2_total) / $m2_total) * 100" | bc -l)
fi

storage_mom_pct=0
if (( $(echo "$m2_storage > 0" | bc -l) )); then
    storage_mom_pct=$(echo "scale=2; (($m1_storage - $m2_storage) / $m2_storage) * 100" | bc -l)
fi

transfer_mom_pct=0
if (( $(echo "$m2_transfer > 0" | bc -l) )); then
    transfer_mom_pct=$(echo "scale=2; (($m1_transfer - $m2_transfer) / $m2_transfer) * 100" | bc -l)
fi

{
    echo "Artifact Registry Month-over-Month Comparison"
    echo "============================================="
    echo "Month 3 (${m3_start}): \$$(printf "%.2f" "$m3_total")"
    echo "Month 2 (${m2_start}): \$$(printf "%.2f" "$m2_total")"
    echo "Month 1 (${m1_start}, most recent complete): \$$(printf "%.2f" "$m1_total")"
    echo ""
    echo "MoM change (month1 vs month2): ${mom_pct}%"
    echo "Storage MoM: ${storage_mom_pct}% (M1=\$${m1_storage}, M2=\$${m2_storage})"
    echo "Transfer/pull MoM: ${transfer_mom_pct}% (M1=\$${m1_transfer}, M2=\$${m2_transfer})"
    echo "Threshold: ${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT}%"
} | tee "$REPORT_FILE"

threshold="${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT:-25}"
if (( $(echo "$mom_pct >= $threshold" | bc -l) )); then
    issue=$(jq -n \
        --arg title "Artifact Registry Spend Growth Exceeds MoM Threshold" \
        --argjson severity 2 \
        --arg mom "$mom_pct" \
        --arg threshold "$threshold" \
        --arg m1 "$m1_total" \
        --arg m2 "$m2_total" \
        '{
          title: $title,
          severity: $severity,
          expected: ("Artifact spend should not grow more than " + $threshold + "% month-over-month"),
          actual: ("Spend grew " + $mom + "% from $" + $m2 + " to $" + $m1),
          details: ("Month-over-month artifact spend increased " + $mom + "% (threshold " + $threshold + "%)."),
          next_steps: "Identify new repositories or tags driving growth. Enable cleanup policies and retire unused legacy GCR images."
        }')
    append_issue "$ISSUES_FILE" "$issue"
fi

if (( $(echo "$storage_mom_pct >= $threshold" | bc -l) )) && (( $(echo "$transfer_mom_pct < 10" | bc -l) )); then
    issue=$(jq -n \
        --arg title "Artifact Storage Costs Rising Without Pull Activity" \
        --argjson severity 2 \
        --arg storage_mom "$storage_mom_pct" \
        --arg transfer_mom "$transfer_mom_pct" \
        '{
          title: $title,
          severity: $severity,
          expected: "Storage cost growth should correlate with artifact pull/transfer activity",
          actual: ("Storage MoM " + $storage_mom + "% while transfer MoM " + $transfer_mom + "%"),
          details: "Artifact storage spend is growing faster than egress/pull charges, suggesting stale image accumulation.",
          next_steps: "Run gcp-artifact-registry-governance inventory tasks and enable cleanup policies for untagged or aged artifacts."
        }')
    append_issue "$ISSUES_FILE" "$issue"
fi

cp "$ISSUES_FILE" artifact_mom_output.json
echo "Month-over-month comparison completed."
