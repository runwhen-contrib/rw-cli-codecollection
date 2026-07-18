#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_BUDGET_USD:=0}"
: "${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS:=7}"

OUTPUT_FILE="forecast_issues.json"
issues_json='[]'

echo "Forecasting OpenRouter spend trend..."

now=$(date +%s)
start_time=$((now - OPENROUTER_LOOKBACK_DAYS * 86400))

all_logs='[]'
offset=0
limit=200

while true; do
    if ! resp=$(curl -s --max-time 30 \
      -H "Authorization: Bearer $OPENROUTER_API_KEY" \
      "https://openrouter.ai/api/v1/logs?offset=$offset&limit=$limit&start_time=$start_time" 2>err.log); then
        err_msg=$(cat err.log)
        rm -f err.log
        issues_json=$(echo "$issues_json" | jq \
          --arg title "Cannot Fetch OpenRouter Logs for Forecast" \
          --arg details "API call to /api/v1/logs failed at offset=$offset: $err_msg" \
          --arg severity "3" \
          --arg next_steps "Verify network connectivity" \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
        echo "$issues_json" > "$OUTPUT_FILE"
        exit 0
    fi
    rm -f err.log

    batch=$(echo "$resp" | jq -c '.data // []')
    count=$(echo "$batch" | jq 'length')
    all_logs=$(echo "$all_logs" | jq --argjson batch "$batch" '. + $batch')

    if [ "$count" -lt "$limit" ]; then
        break
    fi
    offset=$((offset + limit))
done

total_logs=$(echo "$all_logs" | jq 'length')
echo "Fetched $total_logs log entries."

if [ "$total_logs" -lt 2 ]; then
    echo "Not enough data points for forecasting (need at least 2)."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

daily_spend=$(echo "$all_logs" | jq -r '
  group_by(.created_at[:10]) |
  map({
    date: .[0].created_at[:10],
    total_spend: (map(.total_cost | select(. != null) | tonumber) | add // 0)
  }) |
  sort_by(.date)
')

echo "Daily spend data:"
echo "$daily_spend" | jq -r '.[] | "\(.date): $\(.total_spend)"'

daily_values=$(echo "$daily_spend" | jq '[.[].total_spend]')
num_days=$(echo "$daily_values" | jq 'length')
sum=$(echo "$daily_values" | jq 'add // 0')

if [ "$(echo "$num_days > 0" | bc -l)" -eq 1 ]; then
    avg_daily_burn=$(echo "scale=6; $sum / $num_days" | bc -l)
else
    avg_daily_burn=0
fi

echo "Average daily burn rate: \$$avg_daily_burn"

variance_sum=0
for value in $(echo "$daily_values" | jq -r '.[]'); do
    diff=$(echo "scale=6; $value - $avg_daily_burn" | bc -l)
    diff_sq=$(echo "scale=6; $diff * $diff" | bc -l)
    variance_sum=$(echo "scale=6; $variance_sum + $diff_sq" | bc -l)
done

if [ "$(echo "$num_days > 1" | bc -l)" -eq 1 ]; then
    variance=$(echo "scale=6; $variance_sum / $num_days" | bc -l)
    stddev=$(echo "scale=6; sqrt($variance)" | bc -l)
else
    stddev=0
fi

echo "Daily spend standard deviation: \$$stddev"

projected_weekly=$(echo "scale=2; $avg_daily_burn * 7" | bc -l)
projected_monthly=$(echo "scale=2; $avg_daily_burn * 30" | bc -l)

echo "Projected weekly spend: \$$projected_weekly"
echo "Projected monthly spend: \$$projected_monthly"

budget=$(echo "$OPENROUTER_BUDGET_USD" | jq -r '. // 0')
if [ "$(echo "$budget > 0 && $avg_daily_burn > 0" | bc -l)" -eq 1 ]; then
    projected_usage_monthly=$projected_monthly
    if [ "$(echo "$projected_usage_monthly > $budget" | bc -l)" -eq 1 ]; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "OpenRouter Spend Projected to Exceed Monthly Budget" \
          --arg details "At the current average daily burn rate of \$$avg_daily_burn, projected monthly spend is \$$projected_monthly, which exceeds the configured budget of \$$budget. Daily variance: \$$stddev." \
          --arg severity "3" \
          --arg next_steps "Reduce spend or increase the budget. Consider setting usage limits at https://openrouter.ai/settings/limits." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
fi

if ! api_response=$(curl -s --max-time 30 \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  "https://openrouter.ai/api/v1/auth/key" 2>/dev/null); then
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

credits=$(echo "$api_response" | jq -r '.credits // "0"')
if [ "$(echo "$credits > 0 && $avg_daily_burn > 0" | bc -l)" -eq 1 ]; then
    days_until_depletion=$(echo "scale=1; $credits / $avg_daily_burn" | bc -l)
    echo "Estimated days until balance depletion: $days_until_depletion"

    if [ "$(echo "$days_until_depletion < $OPENROUTER_BALANCE_ALERT_WINDOW_DAYS" | bc -l)" -eq 1 ]; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "OpenRouter Balance Depletion Imminent" \
          --arg details "At the current daily burn rate of \$$avg_daily_burn, remaining credits (\$$credits) will be depleted in approximately $days_until_depletion days, which is within the alert window of $OPENROUTER_BALANCE_ALERT_WINDOW_DAYS days." \
          --arg severity "4" \
          --arg next_steps "Add funds immediately to prevent service interruption. Visit https://openrouter.ai/settings/credits." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Forecasting completed. Results saved to $OUTPUT_FILE"