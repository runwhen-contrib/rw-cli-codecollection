#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_ANOMALY_STDDEV_THRESHOLD:=2}"

OUTPUT_FILE="anomaly_issues.json"
issues_json='[]'

echo "Detecting OpenRouter spend anomalies..."

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
          --arg title "Cannot Fetch OpenRouter Logs for Anomaly Detection" \
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
    echo "Not enough data for anomaly detection."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

daily_spend=$(echo "$all_logs" | jq -r '
  group_by(.created_at[:10]) |
  map({
    date: .[0].created_at[:10],
    total_spend: (map(.total_cost | select(. != null) | tonumber) | add // 0),
    request_count: length
  }) |
  sort_by(.date)
')

num_days=$(echo "$daily_spend" | jq 'length')
values=$(echo "$daily_spend" | jq '[.[].total_spend]')
sum=$(echo "$values" | jq 'add // 0')

if [ "$(echo "$num_days > 0" | bc -l)" -eq 1 ]; then
    mean=$(echo "scale=6; $sum / $num_days" | bc -l)
else
    mean=0
fi

variance_sum=0
for v in $(echo "$values" | jq -r '.[]'); do
    d=$(echo "scale=6; $v - $mean" | bc -l)
    ds=$(echo "scale=6; $d * $d" | bc -l)
    variance_sum=$(echo "scale=6; $variance_sum + $ds" | bc -l)
done

if [ "$(echo "$num_days > 1" | bc -l)" -eq 1 ]; then
    variance=$(echo "scale=6; $variance_sum / $num_days" | bc -l)
    stddev=$(echo "scale=6; sqrt($variance)" | bc -l)
else
    stddev=0
fi

echo "Mean daily spend: \$$mean, StdDev: \$$stddev"

spike_detected=0
acceleration_detected=0

echo "$daily_spend" | jq -c '.[]' | while read -r day; do
    date=$(echo "$day" | jq -r '.date')
    spend=$(echo "$day" | jq -r '.total_spend')

    if [ "$(echo "$stddev > 0" | bc -l)" -eq 1 ]; then
        z_score=$(echo "scale=4; ($spend - $mean) / $stddev" | bc -l)
        abs_z=$(echo "scale=4; $z_score / 1" | bc -l | sed 's/-//')

        if [ "$(echo "$abs_z > $OPENROUTER_ANOMALY_STDDEV_THRESHOLD" | bc -l)" -eq 1 ] && [ "$(echo "$spend > $mean" | bc -l)" -eq 1 ]; then
            issues_json=$(echo "$issues_json" | jq \
              --arg title "OpenRouter Spend Spike Detected on $date" \
              --arg details "Spend on $date was \$$spend (z-score: $z_score), which exceeds the anomaly threshold of $OPENROUTER_ANOMALY_STDDEV_THRESHOLD standard deviations from the mean (\$$mean)." \
              --arg severity "3" \
              --arg next_steps "Investigate the cause of the spend spike on $date. Check for unusual model usage, traffic surges, or configuration changes." \
              '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
            spike_detected=1
        fi
    fi
done

if [ "$num_days" -ge 3 ]; then
    first_half=$(echo "$daily_spend" | jq '[.[: ($len | length / 2 | floor)]] | .[0][].total_spend' --arg len "$num_days" | jq -s 'add // 0')
    second_half=$(echo "$daily_spend" | jq '[.[($len | length / 2 | floor):]] | .[0][].total_spend' --arg len "$num_days" | jq -s 'add // 0')
    first_count=$(echo "$num_days / 2" | bc)
    second_count=$((num_days - first_count))

    if [ "$first_count" -gt 0 ] && [ "$second_count" -gt 0 ]; then
        first_avg=$(echo "scale=6; $first_half / $first_count" | bc -l)
        second_avg=$(echo "scale=6; $second_half / $second_count" | bc -l)

        if [ "$(echo "$first_avg > 0" | bc -l)" -eq 1 ]; then
            acceleration_ratio=$(echo "scale=4; $second_avg / $first_avg" | bc -l)
            if [ "$(echo "$acceleration_ratio > 1.5" | bc -l)" -eq 1 ]; then
                issues_json=$(echo "$issues_json" | jq \
                  --arg title "OpenRouter Spend Acceleration Detected" \
                  --arg details "Average daily spend has increased from \$$first_avg (first half) to \$$second_avg (second half), a ${acceleration_ratio}x increase. This sustained acceleration may indicate a growing usage pattern." \
                  --arg severity "3" \
                  --arg next_steps "Review recent changes in model usage, user onboarding, or application traffic that may be driving increased spend." \
                  '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
                acceleration_detected=1
            fi
        fi
    fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Spike detected: $spike_detected, Acceleration detected: $acceleration_detected"
echo "Anomaly detection completed. Results saved to $OUTPUT_FILE"