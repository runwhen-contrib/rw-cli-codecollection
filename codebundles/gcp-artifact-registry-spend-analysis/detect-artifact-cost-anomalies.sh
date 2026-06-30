#!/usr/bin/env bash
set -euo pipefail
set -x

# Detect daily artifact storage cost spikes and sustained weekly deviations.

source "$(dirname "$0")/artifact-billing-common.sh"

REPORT_FILE="${REPORT_FILE:-artifact_anomaly_report.txt}"
ISSUES_FILE="${ISSUES_FILE:-artifact_anomaly_issues.json}"

init_issues_file "$ISSUES_FILE"

if ! ensure_billing_context; then
    cp "$ISSUES_FILE" artifact_anomaly_output.json
    cat "$ISSUES_FILE"
    exit 0
fi

lookback_start=$(echo "$DATE_RANGES" | jq -r '.lookback.start')
lookback_end=$(echo "$DATE_RANGES" | jq -r '.lookback.end')
week_start=$(echo "$DATE_RANGES" | jq -r '.weekly.start')
week_end=$(echo "$DATE_RANGES" | jq -r '.weekly.end')
month_start=$(echo "$DATE_RANGES" | jq -r '.monthly.start')
month_end=$(echo "$DATE_RANGES" | jq -r '.monthly.end')

storage_filter="AND $(artifact_storage_sku_filter_sql)"
sku_filter=$(artifact_sku_filter_sql)

query="
SELECT
  sku.description AS sku_description,
  service.description AS service_name,
  DATE(usage_start_time) AS usage_date,
  SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) >= '${lookback_start}'
  AND DATE(usage_start_time) <= '${lookback_end}'
  AND ${sku_filter}
  ${storage_filter}
  ${PROJECT_FILTER}
GROUP BY sku_description, service_name, usage_date
ORDER BY usage_date DESC
"

rows=$(run_bq_json_query "$BILLING_TABLE" "$query")

aggregated=$(echo "$rows" | jq --argjson ranges "$DATE_RANGES" '
  group_by(.sku_description) |
  map({
    sku: .[0].sku_description,
    service: .[0].service_name,
    daily: ($ranges.daily | map(. as $date | {
      date: $date,
      cost: ([.[] | select(.usage_date == $date) | .total_cost | tonumber] | add // 0)
    })),
    weeklyCost: ([.[] | select(.usage_date >= $ranges.weekly.start and .usage_date <= $ranges.weekly.end) | .total_cost | tonumber] | add // 0),
    monthlyCost: ([.[] | select(.usage_date >= $ranges.monthly.start and .usage_date <= $ranges.monthly.end) | .total_cost | tonumber] | add // 0)
  })
')

spike_multiplier="${ARTIFACT_COST_SPIKE_MULTIPLIER:-2}"
spike_count=0
weekly_deviation_count=0

while IFS= read -r sku_data; do
    [[ -z "$sku_data" ]] && continue
    sku=$(echo "$sku_data" | jq -r '.sku')
    service=$(echo "$sku_data" | jq -r '.service')
    daily_costs=$(echo "$sku_data" | jq -r '.daily[].cost')
    avg_daily=$(echo "$daily_costs" | awk 'BEGIN{sum=0; count=0} $1>0{sum+=$1; count++} END{if(count>0) print sum/count; else print 0}')

    while IFS= read -r day; do
        [[ -z "$day" ]] && continue
        date=$(echo "$day" | jq -r '.date')
        cost=$(echo "$day" | jq -r '.cost')
        if (( $(echo "$cost > 0 && $avg_daily > 0" | bc -l) )); then
            multiplier=$(echo "scale=2; $cost / $avg_daily" | bc -l)
            if (( $(echo "$multiplier >= $spike_multiplier" | bc -l) )); then
                issue=$(jq -n \
                    --arg title "Artifact Storage Cost Spike: \`${sku}\` on ${date}" \
                    --argjson severity 2 \
                    --arg sku "$sku" \
                    --arg service "$service" \
                    --arg date "$date" \
                    --arg cost "$cost" \
                    --arg avg "$avg_daily" \
                    --arg multiplier "$multiplier" \
                    '{
                      title: $title,
                      severity: $severity,
                      expected: ("Daily artifact storage cost should stay near 7-day average ($" + $avg + ")"),
                      actual: ("Cost on " + $date + " was $" + $cost + " (" + $multiplier + "x average)"),
                      details: ("Service: " + $service + "\nSKU: " + $sku),
                      next_steps: "Check for bulk image pushes, failed cleanup jobs, or scanning charges on the spike date."
                    }')
                append_issue "$ISSUES_FILE" "$issue"
                spike_count=$((spike_count + 1))
            fi
        fi
    done < <(echo "$sku_data" | jq -c '.daily[]')

    weekly_cost=$(echo "$sku_data" | jq -r '.weeklyCost')
    monthly_cost=$(echo "$sku_data" | jq -r '.monthlyCost')
    if (( $(echo "$monthly_cost > 0 && $weekly_cost > 0" | bc -l) )); then
        expected_weekly=$(echo "scale=2; $monthly_cost * 7 / 30" | bc -l)
        weekly_ratio=$(echo "scale=2; $weekly_cost / $expected_weekly" | bc -l)
        if (( $(echo "$weekly_ratio >= 1.5" | bc -l) )); then
            increase_percent=$(echo "scale=1; ($weekly_ratio - 1) * 100" | bc -l)
            issue=$(jq -n \
                --arg title "Sustained Artifact Storage Cost Deviation: \`${sku}\`" \
                --argjson severity 2 \
                --arg sku "$sku" \
                --arg weekly "$weekly_cost" \
                --arg expected "$expected_weekly" \
                --arg increase "$increase_percent" \
                '{
                  title: $title,
                  severity: $severity,
                  expected: ("Weekly artifact storage should track 30-day trend (~$" + $expected + ")"),
                  actual: ("Last 7 days cost $" + $weekly + ", " + $increase + "% above trend"),
                  details: ("SKU `" + $sku + "` weekly spend deviates from 30-day baseline."),
                  next_steps: "Audit repository growth and duplicate tags. Correlate with governance bundle inventory output."
                }')
            append_issue "$ISSUES_FILE" "$issue"
            weekly_deviation_count=$((weekly_deviation_count + 1))
        fi
    fi
done < <(echo "$aggregated" | jq -c '.[]')

{
    echo "Artifact Storage Cost Anomaly Detection"
    echo "======================================="
    echo "Spike threshold: ${spike_multiplier}x 7-day average"
    echo "Daily spikes detected: ${spike_count}"
    echo "Weekly deviations detected: ${weekly_deviation_count}"
    echo "Analysis window: ${lookback_start} to ${lookback_end}"
} | tee "$REPORT_FILE"

cp "$ISSUES_FILE" artifact_anomaly_output.json
echo "Anomaly detection completed."
