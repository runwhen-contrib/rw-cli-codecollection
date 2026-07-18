#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD:=50}"

OUTPUT_FILE="model_spend_issues.json"
issues_json='[]'

echo "Analyzing OpenRouter spend by model for last $OPENROUTER_LOOKBACK_DAYS days..."

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
          --arg title "Cannot Fetch OpenRouter Logs for Model Analysis" \
          --arg details "API call to /api/v1/logs failed at offset=$offset: $err_msg" \
          --arg severity "3" \
          --arg next_steps "Verify network connectivity and API key permissions" \
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

if [ "$total_logs" -eq 0 ]; then
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

model_spend=$(echo "$all_logs" | jq -r '
  group_by(.model // "unknown") |
  map({
    model: .[0].model // "unknown",
    total_spend: (map(.total_cost | select(. != null) | tonumber) | add // 0),
    request_count: length
  }) |
  sort_by(-.total_spend)')

total_spend=$(echo "$model_spend" | jq '[.[].total_spend] | add // 0')
echo "Total spend across all models: \$$total_spend"

echo "$model_spend" | jq -r '.[] | "\(.model): $\(.total_spend) (\(.request_count) requests)"'

if [ "$(echo "$total_spend > 0" | bc -l)" -eq 1 ]; then
    top_model=$(echo "$model_spend" | jq -r '.[0] // empty')
    if [ -n "$top_model" ]; then
        top_model_name=$(echo "$top_model" | jq -r '.model')
        top_model_spend=$(echo "$top_model" | jq -r '.total_spend')
        top_model_pct=$(echo "scale=2; $top_model_spend * 100 / $total_spend" | bc -l)

        echo "Top model: $top_model_name at ${top_model_pct}% of total spend"

        if [ "$(echo "$top_model_pct > $OPENROUTER_SPEND_CONCENTRATION_THRESHOLD" | bc -l)" -eq 1 ]; then
            issues_json=$(echo "$issues_json" | jq \
              --arg title "OpenRouter Spend Concentration Risk: $top_model_name" \
              --arg details "Model $top_model_name accounts for ${top_model_pct}% (\$$top_model_spend) of total spend (\$$total_spend), exceeding the concentration threshold of ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}%." \
              --arg severity "3" \
              --arg next_steps "Review usage of $top_model_name. Consider distributing load across alternative models or negotiating better pricing for the dominant model." \
              '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
        fi
    fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Model spend analysis completed. Results saved to $OUTPUT_FILE"