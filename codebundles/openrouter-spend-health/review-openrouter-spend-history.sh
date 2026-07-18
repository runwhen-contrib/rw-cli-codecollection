#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"

OUTPUT_FILE="spend_history_issues.json"
issues_json='[]'

echo "Reviewing OpenRouter spend history for last $OPENROUTER_LOOKBACK_DAYS days..."

now=$(date +%s)
lookback_seconds=$((OPENROUTER_LOOKBACK_DAYS * 86400))
start_time=$((now - lookback_seconds))

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
          --arg title "Cannot Fetch OpenRouter Spend Logs" \
          --arg details "API call to /api/v1/logs failed at offset=$offset: $err_msg" \
          --arg severity "3" \
          --arg next_steps "Verify network connectivity and that the API key has permissions to access logs" \
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
echo "Fetched $total_logs log entries for the lookback period."

if [ "$total_logs" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "No OpenRouter Generation Logs Found" \
      --arg details "No generation logs were found in the last $OPENROUTER_LOOKBACK_DAYS days. This may indicate no API usage or missing log retention." \
      --arg severity "2" \
      --arg next_steps "Check if the OpenRouter API key has been used recently. Verify the lookback window is appropriate." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

daily_totals=$(echo "$all_logs" | jq -r '
  group_by(.created_at[:10]) |
  map({
    date: .[0].created_at[:10],
    total_spend: (map(.total_cost | select(. != null) | tonumber) | add // 0),
    count: length
  }) |
  sort_by(.date) | .[]
')

echo "Daily spend breakdown:"
echo "$daily_totals" | jq -r '"\(.date): $\(.total_spend) (\(.count) requests)"'

daily_dates=$(echo "$daily_totals" | jq -r '.date')
for d in $(seq 0 $((OPENROUTER_LOOKBACK_DAYS - 1))); do
    check_date=$(date -d "@$((now - d * 86400))" +%Y-%m-%d)
    if ! echo "$daily_dates" | grep -q "$check_date"; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "Missing OpenRouter Spend Data for $check_date" \
          --arg details "No generation logs found for date $check_date within the lookback window. This may indicate a gap in logging." \
          --arg severity "2" \
          --arg next_steps "Investigate whether the OpenRouter API was unavailable or if logging was interrupted on this date." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
done

cumulative_spend=$(echo "$daily_totals" | jq '[.total_spend] | add // 0')
echo "Total cumulative spend in lookback window: \$$cumulative_spend"

echo "$issues_json" > "$OUTPUT_FILE"
echo "Spend history review completed. Results saved to $OUTPUT_FILE"