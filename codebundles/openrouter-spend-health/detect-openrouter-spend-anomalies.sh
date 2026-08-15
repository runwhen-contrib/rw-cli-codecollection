#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_LOOKBACK_DAYS:=7}"
: "${OPENROUTER_ANOMALY_STDDEV_THRESHOLD:=2}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="anomaly_issues.json"
issues_json='[]'

echo "Detecting OpenRouter spend anomalies..."

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
      --arg details "The /activity endpoint returned HTTP 403. Anomaly detection requires a management key." \
      --arg severity "3" \
      --arg next_steps "Use a management API key or disable anomaly detection for non-management keys." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
  fi

  if [ "$http_code" != "200" ]; then
    err_msg=$(echo "$resp" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Fetch OpenRouter Activity for Anomaly Detection" \
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
  echo "Not enough data for anomaly detection."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

daily_spend=$(echo "$all_activity" | jq '
  group_by(.date) |
  map({
    date: .[0].date,
    total_spend: (map(.usage // 0) | add // 0),
    request_count: (map(.requests // 0) | add // 0)
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

zscores=$(echo "$daily_spend" | jq --arg mean "$mean" --arg stddev "$stddev" '
  map(
    . as $d
    | $d + {
        z_score: (
          if ($stddev | tonumber) > 0
          then (($d.total_spend - ($mean | tonumber)) / ($stddev | tonumber))
          else 0
          end
        )
      }
  )
')

echo "=== REPORT: ANOMALY INPUT SERIES (JSON) ==="
echo "$zscores" | jq '.'

spike_detected=0
acceleration_detected=0

while IFS= read -r day; do
  date=$(echo "$day" | jq -r '.date')
  spend=$(echo "$day" | jq -r '.total_spend')

  if [ "$(echo "$stddev > 0" | bc -l)" -eq 1 ]; then
    z_score=$(echo "scale=4; ($spend - $mean) / $stddev" | bc -l)
    abs_z=$(echo "$z_score" | sed 's/-//')

    if [ "$(echo "$abs_z > $OPENROUTER_ANOMALY_STDDEV_THRESHOLD" | bc -l)" -eq 1 ] && [ "$(echo "$spend > $mean" | bc -l)" -eq 1 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "OpenRouter Spend Spike Detected on $date" \
        --arg details "Spend on $date was \$$spend (z-score: $z_score), above threshold $OPENROUTER_ANOMALY_STDDEV_THRESHOLD from mean \$$mean." \
        --arg severity "3" \
        --arg next_steps "Review model usage, traffic, and recent deployments for this date." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
      spike_detected=1
    fi
  fi
done < <(echo "$daily_spend" | jq -c '.[]')

if [ "$num_days" -ge 3 ]; then
  split_index=$((num_days / 2))
  first_half=$(echo "$daily_spend" | jq "[.[0:$split_index][].total_spend] | add // 0")
  second_half=$(echo "$daily_spend" | jq "[.[$split_index:][].total_spend] | add // 0")
  first_count=$split_index
  second_count=$((num_days - split_index))

  if [ "$first_count" -gt 0 ] && [ "$second_count" -gt 0 ]; then
    first_avg=$(echo "scale=6; $first_half / $first_count" | bc -l)
    second_avg=$(echo "scale=6; $second_half / $second_count" | bc -l)

    if [ "$(echo "$first_avg > 0" | bc -l)" -eq 1 ]; then
      acceleration_ratio=$(echo "scale=4; $second_avg / $first_avg" | bc -l)
      if [ "$(echo "$acceleration_ratio > 1.5" | bc -l)" -eq 1 ]; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "OpenRouter Spend Acceleration Detected" \
          --arg details "Average daily spend increased from \$$first_avg (first half) to \$$second_avg (second half), a ${acceleration_ratio}x increase." \
          --arg severity "3" \
          --arg next_steps "Review onboarding, routing, and model mix changes driving sustained growth." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
        acceleration_detected=1
      fi
    fi
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Spike detected: $spike_detected, Acceleration detected: $acceleration_detected"
echo "Anomaly detection completed. Results saved to $OUTPUT_FILE"