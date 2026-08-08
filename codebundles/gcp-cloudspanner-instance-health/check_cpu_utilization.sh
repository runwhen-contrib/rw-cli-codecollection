#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   CPU_UTILIZATION_THRESHOLD               (default 65)  -- ceiling for regional instances
#   MULTI_REGION_CPU_UTILIZATION_THRESHOLD  (default 45)  -- ceiling for multi-region instances
#
# This script:
#   1) Lists all Cloud Spanner instances in the project
#   2) Reads HIGH-PRIORITY CPU utilization from Cloud Monitoring
#      (spanner.googleapis.com/instance/cpu/utilization_by_priority,
#      filtered to metric.labels.priority="high") -- NOT total CPU, since
#      Google's SLO guidance and alerting is based on high-priority CPU.
#   3) Applies a lower ceiling to multi-region instances (45%) than regional
#      instances (65%), derived from the instance's config.
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${CPU_UTILIZATION_THRESHOLD:=65}"
: "${MULTI_REGION_CPU_UTILIZATION_THRESHOLD:=45}"

# `gcloud monitoring time-series list` does not exist; query the REST API.
source "$(dirname "$0")/monitoring_query.sh"

OUTPUT_FILE="cpu_utilization_issues.json"

echo "Checking Cloud Spanner high-priority CPU utilization for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# Look back 10 minutes for a recent CPU sample.
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")

> /tmp/cpu_util_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')
  config=$(echo "$inst" | jq -r '.config // ""' | awk -F/ '{print $NF}')

  is_multi_region="true"
  threshold="$MULTI_REGION_CPU_UTILIZATION_THRESHOLD"
  case "$config" in
    regional-*)
      is_multi_region="false"
      threshold="$CPU_UTILIZATION_THRESHOLD"
      ;;
  esac

  metric_filter="metric.type=\"spanner.googleapis.com/instance/cpu/utilization_by_priority\" AND resource.labels.instance_id=\"$instance_id\" AND metric.labels.priority=\"high\""

  series=$(query_time_series "$metric_filter" "$start_time" "$end_time")

  # Average the most recent points across returned series (double value is a 0-1 ratio).
  avg_ratio=$(echo "$series" | jq '[.[].points[]?.value.doubleValue // empty] | if length > 0 then (add / length) else -1 end')

  if [ "$avg_ratio" = "-1" ] || [ -z "$avg_ratio" ]; then
    echo "No high-priority CPU utilization data available for instance $instance_id; skipping."
    continue
  fi

  cpu_percent=$(python3 -c "print(f'{float($avg_ratio) * 100:.2f}')" 2>/dev/null || echo "0")
  echo "Instance $instance_id: high-priority CPU = ${cpu_percent}% (threshold ${threshold}%, multi_region=$is_multi_region)"

  if python3 -c "exit(0 if float($cpu_percent) > float($threshold) else 1)" 2>/dev/null; then
    severity=3
    if python3 -c "exit(0 if float($cpu_percent) > float($threshold) * 1.15 else 1)" 2>/dev/null; then
      severity=2
    fi
    printf '{"title":"Cloud Spanner instance `%s` exceeds high-priority CPU threshold","details":"Instance `%s` (config: %s, multi_region: %s) high-priority CPU utilization is %s%%, above the %s%% recommended ceiling.","severity":%s,"expected":"High-priority CPU utilization should stay below %s%%","actual":"High-priority CPU utilization is %s%%","next_steps":"Add nodes/processing units to the instance (`gcloud spanner instances update %s --processing-units=<value> --project=%s`) or reduce query/write load. Sustained high-priority CPU above threshold increases latency and error risk.","instance":"%s"}\n' \
      "$instance_id" "$instance_id" "$config" "$is_multi_region" "$cpu_percent" "$threshold" "$severity" "$threshold" "$cpu_percent" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" >> /tmp/cpu_util_parts.jsonl
  fi
done

if [ -s /tmp/cpu_util_parts.jsonl ]; then
  jq -s '.' /tmp/cpu_util_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/cpu_util_parts.jsonl

echo "CPU utilization check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
