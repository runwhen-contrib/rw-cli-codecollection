#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_BUDGET_USD:=0}"
: "${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS:=7}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="forecast_issues.json"
issues_json='[]'

echo "Forecasting OpenRouter spend trend..."

if [ "$OPENROUTER_LOOKBACK_DAYS" -gt 30 ]; then
  echo "OPENROUTER_LOOKBACK_DAYS exceeds /activity API retention window; capping to 30"
  OPENROUTER_LOOKBACK_DAYS=30
fi

get_with_status() {
  local path="$1"
  local tmp status body
  tmp=$(mktemp)
  status=$(curl -s -S --max-time 30 -o "$tmp" -w "%{http_code}" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    "$OPENROUTER_API_BASE_URL$path" || true)
  body=$(cat "$tmp")
  rm -f "$tmp"
  printf '%s\n%s\n' "$status" "$body"
}

all_activity='[]'

for d in $(seq 1 "$OPENROUTER_LOOKBACK_DAYS"); do
  check_date=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(days=$d)).strftime('%Y-%m-%d'))")
  result=$(get_with_status "/activity?date=$check_date")
  http_code=$(echo "$result" | sed -n '1p')
  resp=$(echo "$result" | sed -n '2,$p')

  if [ "$http_code" = "403" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenRouter Activity Endpoint Requires Management Key" \
      --arg details "The /activity endpoint returned HTTP 403. Forecasting requires a management key." \
      --arg severity "3" \
      --arg next_steps "Use a management API key or switch to key-level forecast inputs only." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi

  if [ "$http_code" != "200" ]; then
    err_msg=$(echo "$resp" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Fetch OpenRouter Activity for Forecast" \
      --arg details "API call to /activity for $check_date failed with HTTP $http_code: $err_msg" \
      --arg severity "3" \
      --arg next_steps "Verify API access and retry." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi

  day_data=$(echo "$resp" | jq -c --arg date "$check_date" '[.data[]? | . + {date: (.date // $date)}]')
  all_activity=$(echo "$all_activity" | jq --argjson batch "$day_data" '. + $batch')
done

total_rows=$(echo "$all_activity" | jq 'length')
echo "Fetched $total_rows activity rows."

if [ "$total_rows" -lt 2 ]; then
  echo "Not enough data points for forecasting (need at least 2 activity rows)."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

daily_spend=$(echo "$all_activity" | jq '
  group_by(.date) |
  map({
    date: .[0].date,
    total_spend: (map(.usage // 0) | add // 0)
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

projected_weekly=$(echo "scale=2; $avg_daily_burn * 7" | bc -l)
projected_monthly=$(echo "scale=2; $avg_daily_burn * 30" | bc -l)

echo "Average daily burn rate: \$$avg_daily_burn"
echo "Daily spend standard deviation: \$$stddev"
echo "Projected weekly spend: \$$projected_weekly"
echo "Projected monthly spend: \$$projected_monthly"

budget=$(echo "$OPENROUTER_BUDGET_USD" | jq -r '. // 0')
if [ "$(echo "$budget > 0 && $projected_monthly > $budget" | bc -l)" -eq 1 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter Spend Projected to Exceed Monthly Budget" \
    --arg details "At the current average daily burn rate of \$$avg_daily_burn, projected monthly spend is \$$projected_monthly, above configured budget \$$budget. Daily variance: \$$stddev." \
    --arg severity "3" \
    --arg next_steps "Reduce spend or increase budget. Consider limits at https://openrouter.ai/settings/limits." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

key_result=$(get_with_status "/key")
key_http_code=$(echo "$key_result" | sed -n '1p')
key_response=$(echo "$key_result" | sed -n '2,$p')

if [ "$key_http_code" = "200" ] && echo "$key_response" | jq -e '.data' >/dev/null 2>&1; then
  remaining=$(echo "$key_response" | jq -r '.data.limit_remaining // "null"')
  if [ "$remaining" != "null" ] && [ "$(echo "$remaining > 0 && $avg_daily_burn > 0" | bc -l)" -eq 1 ]; then
    days_until_depletion=$(echo "scale=1; $remaining / $avg_daily_burn" | bc -l)
    echo "Estimated days until limit depletion: $days_until_depletion"

    if [ "$(echo "$days_until_depletion < $OPENROUTER_BALANCE_ALERT_WINDOW_DAYS" | bc -l)" -eq 1 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "OpenRouter Limit Depletion Imminent" \
        --arg details "At current burn rate of \$$avg_daily_burn, remaining limit (\$$remaining) depletes in about $days_until_depletion days (alert window: $OPENROUTER_BALANCE_ALERT_WINDOW_DAYS days)." \
        --arg severity "4" \
        --arg next_steps "Add funds or raise limits to avoid interruption." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Forecasting completed. Results saved to $OUTPUT_FILE"