#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   LATENCY_THRESHOLD_MS          (default 100) -- request latency ceiling (ms)
#   ERROR_RATE_THRESHOLD_PERCENT  (default 1)   -- error/abort rate ceiling (percent)
#
# This script:
#   1) Lists all Cloud Spanner instances in the project
#   2) Reads read/write request latency (99th percentile) from Cloud Monitoring
#      (spanner.googleapis.com/api/request_latencies)
#   3) Reads request error/abort rate from Cloud Monitoring
#      (spanner.googleapis.com/api/request_count, grouped by response status)
#   4) Flags instances exceeding the latency or error-rate thresholds
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LATENCY_THRESHOLD_MS:=100}"
: "${ERROR_RATE_THRESHOLD_PERCENT:=1}"

OUTPUT_FILE="latency_errors_issues.json"

echo "Analyzing Cloud Spanner request latency and errors for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")

> /tmp/latency_errors_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  # --- Request latency (99th percentile, all methods) ---
  latency_filter="metric.type=\"spanner.googleapis.com/api/request_latencies\" AND resource.labels.instance_id=\"$instance_id\""
  latency_series=$(gcloud monitoring time-series list \
    --project="$GCP_PROJECT_ID" \
    --filter="$latency_filter" \
    --interval-start-time="$start_time" \
    --interval-end-time="$end_time" \
    --format=json 2>/dev/null || echo "[]")

  p99_latency_ms=$(echo "$latency_series" | jq '[.[].points[]?.value.distributionValue.mean // empty] | if length > 0 then (add / length) else -1 end' 2>/dev/null || echo "-1")

  if [ "$p99_latency_ms" != "-1" ] && [ -n "$p99_latency_ms" ]; then
    latency_ms=$(python3 -c "print(f'{float($p99_latency_ms):.2f}')" 2>/dev/null || echo "0")
    echo "Instance $instance_id: mean request latency = ${latency_ms}ms (threshold ${LATENCY_THRESHOLD_MS}ms)"

    if python3 -c "exit(0 if float($latency_ms) > float($LATENCY_THRESHOLD_MS) else 1)" 2>/dev/null; then
      printf '{"title":"Cloud Spanner instance `%s` exceeds request latency threshold","details":"Instance `%s` mean request latency is %sms, above the %sms threshold.","severity":3,"expected":"Request latency should stay below %sms","actual":"Request latency is %sms","next_steps":"Check for hot spots, missing indexes, or high-priority CPU saturation on `%s`; consider adding nodes/processing units if load-driven.","instance":"%s"}\n' \
        "$instance_id" "$instance_id" "$latency_ms" "$LATENCY_THRESHOLD_MS" "$LATENCY_THRESHOLD_MS" "$latency_ms" "$instance_id" "$instance_id" >> /tmp/latency_errors_parts.jsonl
    fi
  else
    echo "No latency data available for instance $instance_id; skipping latency check."
  fi

  # --- Error / abort rate ---
  total_filter="metric.type=\"spanner.googleapis.com/api/request_count\" AND resource.labels.instance_id=\"$instance_id\""
  total_series=$(gcloud monitoring time-series list \
    --project="$GCP_PROJECT_ID" \
    --filter="$total_filter" \
    --interval-start-time="$start_time" \
    --interval-end-time="$end_time" \
    --format=json 2>/dev/null || echo "[]")

  total_count=$(echo "$total_series" | jq '[.[].points[]?.value.int64Value // .[].points[]?.value.doubleValue // empty] | map(tonumber) | add // 0' 2>/dev/null || echo "0")

  error_filter="metric.type=\"spanner.googleapis.com/api/request_count\" AND resource.labels.instance_id=\"$instance_id\" AND metric.labels.status!=\"OK\""
  error_series=$(gcloud monitoring time-series list \
    --project="$GCP_PROJECT_ID" \
    --filter="$error_filter" \
    --interval-start-time="$start_time" \
    --interval-end-time="$end_time" \
    --format=json 2>/dev/null || echo "[]")

  error_count=$(echo "$error_series" | jq '[.[].points[]?.value.int64Value // .[].points[]?.value.doubleValue // empty] | map(tonumber) | add // 0' 2>/dev/null || echo "0")

  if [ "$total_count" != "0" ] && [ -n "$total_count" ]; then
    error_rate_percent=$(python3 -c "print(f'{(float($error_count) / float($total_count) * 100):.2f}')" 2>/dev/null || echo "0")
    echo "Instance $instance_id: error rate = ${error_rate_percent}% ($error_count/$total_count) (threshold ${ERROR_RATE_THRESHOLD_PERCENT}%)"

    if python3 -c "exit(0 if float($error_rate_percent) > float($ERROR_RATE_THRESHOLD_PERCENT) else 1)" 2>/dev/null; then
      printf '{"title":"Cloud Spanner instance `%s` exceeds error/abort rate threshold","details":"Instance `%s` request error rate is %s%% (%s of %s requests), above the %s%% threshold.","severity":3,"expected":"Request error/abort rate should stay below %s%%","actual":"Error/abort rate is %s%%","next_steps":"Review aborted transaction rate (contention/hotspotting) and application-level retry logic on `%s`.","instance":"%s"}\n' \
        "$instance_id" "$instance_id" "$error_rate_percent" "$error_count" "$total_count" "$ERROR_RATE_THRESHOLD_PERCENT" "$ERROR_RATE_THRESHOLD_PERCENT" "$error_rate_percent" "$instance_id" "$instance_id" >> /tmp/latency_errors_parts.jsonl
    fi
  else
    echo "No request-count data available for instance $instance_id; skipping error-rate check."
  fi
done

if [ -s /tmp/latency_errors_parts.jsonl ]; then
  jq -s '.' /tmp/latency_errors_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/latency_errors_parts.jsonl

echo "Latency/error analysis completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
