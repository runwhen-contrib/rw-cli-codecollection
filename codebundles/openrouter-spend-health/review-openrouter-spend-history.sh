#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="spend_history_issues.json"
issues_json='[]'

echo "Reviewing OpenRouter spend history for last $OPENROUTER_LOOKBACK_DAYS days..."

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
      --arg details "The /activity endpoint returned HTTP 403. Spend-history analysis requires a management key." \
      --arg severity "3" \
      --arg next_steps "Use a management API key, or remove activity-based checks for non-management keys." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi

  if [ "$http_code" != "200" ]; then
    err_msg=$(echo "$resp" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Fetch OpenRouter Activity Data" \
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
echo "Fetched $total_rows activity rows for the lookback period."

if [ "$total_rows" -eq 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No OpenRouter Activity Rows Found" \
    --arg details "No activity rows were found in the last $OPENROUTER_LOOKBACK_DAYS days." \
    --arg severity "2" \
    --arg next_steps "Check if the management API key has usage and if the lookback window is appropriate." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

daily_totals=$(echo "$all_activity" | jq '
  group_by(.date) |
  map({
    date: .[0].date,
    total_spend: (map(.usage // 0) | add // 0),
    count: (map(.requests // 0) | add // 0)
  }) |
  sort_by(.date)
')

echo "Daily spend breakdown:"
echo "$daily_totals" | jq -r '.[] | "\(.date): $\(.total_spend) (\(.count) requests)"'

daily_dates=$(echo "$daily_totals" | jq -r '.[].date')
for d in $(seq 1 "$OPENROUTER_LOOKBACK_DAYS"); do
  check_date=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(days=$d)).strftime('%Y-%m-%d'))")
  if ! echo "$daily_dates" | grep -q "$check_date"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Missing OpenRouter Spend Data for $check_date" \
      --arg details "No activity rows found for date $check_date within the lookback window." \
      --arg severity "2" \
      --arg next_steps "Investigate whether there was no traffic or if reporting data is unavailable for this day." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
done

cumulative_spend=$(echo "$daily_totals" | jq '[.[].total_spend] | add // 0')
echo "Total cumulative spend in lookback window: \$$cumulative_spend"

echo "$issues_json" > "$OUTPUT_FILE"
echo "Spend history review completed. Results saved to $OUTPUT_FILE"