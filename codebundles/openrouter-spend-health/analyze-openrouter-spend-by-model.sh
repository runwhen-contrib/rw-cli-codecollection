#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD:=50}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="model_spend_issues.json"
issues_json='[]'

echo "Analyzing OpenRouter spend by model for last $OPENROUTER_LOOKBACK_DAYS days..."

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
      --arg details "The /activity endpoint returned HTTP 403. Model-spend analysis requires a management key." \
      --arg severity "3" \
      --arg next_steps "Use a management API key, or disable model-level analysis for non-management keys." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi

  if [ "$http_code" != "200" ]; then
    err_msg=$(echo "$resp" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Fetch OpenRouter Activity for Model Analysis" \
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

if [ "$total_rows" -eq 0 ]; then
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

model_spend=$(echo "$all_activity" | jq '
  group_by(.model // "unknown") |
  map({
    model: (.[0].model // "unknown"),
    total_spend: (map(.usage // 0) | add // 0),
    request_count: (map(.requests // 0) | add // 0)
  }) |
  sort_by(-.total_spend)
')

total_spend=$(echo "$model_spend" | jq '[.[].total_spend] | add // 0')
echo "Total spend across all models: \$$total_spend"

echo "$model_spend" | jq -r '.[] | "\(.model): $\(.total_spend) (\(.request_count) requests)"'

if [ "$(echo "$total_spend > 0" | bc -l)" -eq 1 ]; then
  top_model_name=$(echo "$model_spend" | jq -r '.[0].model // empty')
  top_model_spend=$(echo "$model_spend" | jq -r '.[0].total_spend // 0')

  if [ -n "$top_model_name" ]; then
    top_model_pct=$(echo "scale=2; $top_model_spend * 100 / $total_spend" | bc -l)
    echo "Top model: $top_model_name at ${top_model_pct}% of total spend"

    if [ "$(echo "$top_model_pct > $OPENROUTER_SPEND_CONCENTRATION_THRESHOLD" | bc -l)" -eq 1 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "OpenRouter Spend Concentration Risk: $top_model_name" \
        --arg details "Model $top_model_name accounts for ${top_model_pct}% (\$$top_model_spend) of total spend (\$$total_spend), exceeding the threshold of ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}%." \
        --arg severity "3" \
        --arg next_steps "Review usage of $top_model_name. Consider shifting traffic or tightening limits." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Model spend analysis completed. Results saved to $OUTPUT_FILE"