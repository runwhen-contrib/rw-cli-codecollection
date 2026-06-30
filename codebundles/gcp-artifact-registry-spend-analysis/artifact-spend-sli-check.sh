#!/usr/bin/env bash
set -euo pipefail
set -x

# Lightweight SLI probe: artifact spend health dimensions for 0-1 scoring.

source "$(dirname "$0")/artifact-billing-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-artifact_sli_metrics.json}"

default_metrics='{"anomaly_score":0,"mom_score":0,"share_score":0,"issue_count":1}'

if ! ensure_billing_context; then
    echo "$default_metrics" > "$OUTPUT_FILE"
    exit 0
fi

lookback_start=$(echo "$DATE_RANGES" | jq -r '.lookback.start')
lookback_end=$(echo "$DATE_RANGES" | jq -r '.lookback.end')
rows=$(query_artifact_cost_rows "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$PROJECT_FILTER")

total_cost=$(echo "$rows" | jq '[.[].total_cost | tonumber] | add // 0')
anomaly_score=1
mom_score=1
share_score=1
issue_count=0

# Project share check
threshold="${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT:-0}"
if [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$threshold" -gt 0 ]] && (( $(echo "$total_cost > 0" | bc -l) )); then
    max_share=$(echo "$rows" | jq --arg total "$total_cost" '
      group_by(.project_id) |
      map({share: ((map(.total_cost | tonumber) | add // 0) / ($total | tonumber) * 100)}) |
      max_by(.share) | .share // 0
    ')
    if (( $(echo "$max_share >= $threshold" | bc -l) )); then
        share_score=0
        issue_count=$((issue_count + 1))
    fi
fi

# MoM check (most recent two complete months)
months=$(get_last_three_complete_months)
m1_start=$(echo "$months" | jq -r '.month1.start')
m1_end=$(echo "$months" | jq -r '.month1.end')
m2_start=$(echo "$months" | jq -r '.month2.start')
m2_end=$(echo "$months" | jq -r '.month2.end')

query_month_total() {
    local start="$1"
    local end="$2"
    local sku_filter
    sku_filter=$(artifact_sku_filter_sql)
    local query="
SELECT SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) >= '${start}'
  AND DATE(usage_start_time) <= '${end}'
  AND ${sku_filter}
  ${PROJECT_FILTER}
"
    run_bq_json_query "$BILLING_TABLE" "$query" | jq -r '.[0].total_cost // 0'
}

m1_total=$(query_month_total "$m1_start" "$m1_end")
m2_total=$(query_month_total "$m2_start" "$m2_end")
mom_threshold="${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT:-25}"
if (( $(echo "$m2_total > 0" | bc -l) )); then
    mom_pct=$(echo "scale=2; (($m1_total - $m2_total) / $m2_total) * 100" | bc -l)
    if (( $(echo "$mom_pct >= $mom_threshold" | bc -l) )); then
        mom_score=0
        issue_count=$((issue_count + 1))
    fi
fi

# Daily spike check on storage SKUs (last 7 days only for speed)
storage_filter="AND $(artifact_storage_sku_filter_sql)"
sku_filter=$(artifact_sku_filter_sql)
week_start=$(echo "$DATE_RANGES" | jq -r '.weekly.start')
week_end=$(echo "$DATE_RANGES" | jq -r '.weekly.end')
query="
SELECT DATE(usage_start_time) AS usage_date,
  SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS total_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) >= '${week_start}'
  AND DATE(usage_start_time) <= '${week_end}'
  AND ${sku_filter}
  ${storage_filter}
  ${PROJECT_FILTER}
GROUP BY usage_date
"
daily_rows=$(run_bq_json_query "$BILLING_TABLE" "$query")
daily_costs=$(echo "$daily_rows" | jq -r '.[].total_cost')
avg_daily=$(echo "$daily_costs" | awk 'BEGIN{sum=0; count=0} $1>0{sum+=$1; count++} END{if(count>0) print sum/count; else print 0}')
spike_multiplier="${ARTIFACT_COST_SPIKE_MULTIPLIER:-2}"

while IFS= read -r cost; do
    [[ -z "$cost" ]] && continue
    if (( $(echo "$cost > 0 && $avg_daily > 0" | bc -l) )); then
        multiplier=$(echo "scale=2; $cost / $avg_daily" | bc -l)
        if (( $(echo "$multiplier >= $spike_multiplier" | bc -l) )); then
            anomaly_score=0
            issue_count=$((issue_count + 1))
            break
        fi
    fi
done <<< "$daily_costs"

jq -n \
    --argjson anomaly_score "$anomaly_score" \
    --argjson mom_score "$mom_score" \
    --argjson share_score "$share_score" \
    --argjson issue_count "$issue_count" \
    '{
      anomaly_score: $anomaly_score,
      mom_score: $mom_score,
      share_score: $share_score,
      issue_count: $issue_count
    }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
