#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   CPU_UTILIZATION_THRESHOLD               (default 65)
#   MULTI_REGION_CPU_UTILIZATION_THRESHOLD  (default 45)
#   STORAGE_UTILIZATION_THRESHOLD           (default 75)
#   STORAGE_LIMIT_GB_PER_NODE               (default 4096)
#
# This script:
#   1) Lists all Cloud Spanner instances in the project
#   2) Produces a consolidated per-instance JSON health summary (state, CPU,
#      storage, database count) with an overall verdict (healthy/warning/critical)
#   3) Writes the summary to SUMMARY_FILE
#   4) Also writes a JSON array of issues (one per non-healthy instance) to
#      OUTPUT_FILE so the runbook can surface a rollup issue
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${CPU_UTILIZATION_THRESHOLD:=65}"
: "${MULTI_REGION_CPU_UTILIZATION_THRESHOLD:=45}"
: "${STORAGE_UTILIZATION_THRESHOLD:=75}"
: "${STORAGE_LIMIT_GB_PER_NODE:=4096}"

SUMMARY_FILE="health_summary.json"
OUTPUT_FILE="health_summary_issues.json"

echo "Generating Cloud Spanner instance health summary for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  printf '{"project_id":"%s","total_instances":0,"instances":[]}\n' "$GCP_PROJECT_ID" > "$SUMMARY_FILE"
  echo "[]" > "$OUTPUT_FILE"
  jq . "$SUMMARY_FILE"
  exit 0
fi

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")

> /tmp/health_summary_instances.jsonl
> /tmp/health_summary_issues.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')
  state=$(echo "$inst" | jq -r '.state // "UNKNOWN"')
  config=$(echo "$inst" | jq -r '.config // ""' | awk -F/ '{print $NF}')
  node_count=$(echo "$inst" | jq -r '.nodeCount // 0')
  processing_units=$(echo "$inst" | jq -r '.processingUnits // 0')

  is_multi_region="true"
  cpu_threshold="$MULTI_REGION_CPU_UTILIZATION_THRESHOLD"
  case "$config" in
    regional-*)
      is_multi_region="false"
      cpu_threshold="$CPU_UTILIZATION_THRESHOLD"
      ;;
  esac

  database_count=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null | jq 'length' || echo "0")

  cpu_filter="metric.type=\"spanner.googleapis.com/instance/cpu/utilization_by_priority\" AND resource.labels.instance_id=\"$instance_id\" AND metric.labels.priority=\"high\""
  cpu_series=$(gcloud monitoring time-series list --project="$GCP_PROJECT_ID" --filter="$cpu_filter" --interval-start-time="$start_time" --interval-end-time="$end_time" --format=json 2>/dev/null || echo "[]")
  cpu_ratio=$(echo "$cpu_series" | jq '[.[].points[]?.value.doubleValue // empty] | if length > 0 then (add / length) else -1 end' 2>/dev/null || echo "-1")
  cpu_percent="null"
  if [ "$cpu_ratio" != "-1" ] && [ -n "$cpu_ratio" ]; then
    cpu_percent=$(python3 -c "print(f'{float($cpu_ratio) * 100:.2f}')" 2>/dev/null || echo "null")
  fi

  node_equivalent=$(python3 -c "
node_count = $node_count
pu = $processing_units
ne = node_count if node_count > 0 else (pu / 1000.0 if pu > 0 else 0)
print(ne if ne > 0 else 0.1)
" 2>/dev/null || echo "0.1")
  limit_gb=$(python3 -c "print(f'{float($node_equivalent) * float($STORAGE_LIMIT_GB_PER_NODE):.2f}')" 2>/dev/null || echo "$STORAGE_LIMIT_GB_PER_NODE")

  storage_filter="metric.type=\"spanner.googleapis.com/instance/storage/used_bytes\" AND resource.labels.instance_id=\"$instance_id\""
  storage_series=$(gcloud monitoring time-series list --project="$GCP_PROJECT_ID" --filter="$storage_filter" --interval-start-time="$start_time" --interval-end-time="$end_time" --format=json 2>/dev/null || echo "[]")
  used_bytes=$(echo "$storage_series" | jq '[.[].points[]?.value | (.doubleValue // .int64Value // empty)] | if length > 0 then (.[0] | tonumber) else -1 end' 2>/dev/null || echo "-1")
  storage_percent="null"
  if [ "$used_bytes" != "-1" ] && [ -n "$used_bytes" ]; then
    used_gb=$(python3 -c "print(f'{float($used_bytes) / (1000**3):.2f}')" 2>/dev/null || echo "0")
    storage_percent=$(python3 -c "print(f'{(float($used_gb) / float($limit_gb) * 100):.2f}' if float($limit_gb) > 0 else '0')" 2>/dev/null || echo "null")
  fi

  # --- Determine verdict ---
  verdict="healthy"
  reasons=()
  if [ "$state" != "READY" ]; then
    verdict="critical"
    reasons+=("instance state is $state")
  fi
  if [ "$cpu_percent" != "null" ] && python3 -c "exit(0 if float($cpu_percent) > float($cpu_threshold) else 1)" 2>/dev/null; then
    [ "$verdict" = "healthy" ] && verdict="warning"
    reasons+=("high-priority CPU ${cpu_percent}% > ${cpu_threshold}%")
  fi
  if [ "$storage_percent" != "null" ] && python3 -c "exit(0 if float($storage_percent) > float($STORAGE_UTILIZATION_THRESHOLD) else 1)" 2>/dev/null; then
    [ "$verdict" = "healthy" ] && verdict="warning"
    reasons+=("storage ${storage_percent}% > ${STORAGE_UTILIZATION_THRESHOLD}%")
  fi

  reasons_json=$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')

  instance_summary=$(jq -n \
    --arg instance "$instance_id" \
    --arg state "$state" \
    --arg config "$config" \
    --argjson multi_region "$is_multi_region" \
    --argjson node_count "$node_count" \
    --argjson processing_units "$processing_units" \
    --argjson database_count "$database_count" \
    --arg cpu_percent "$cpu_percent" \
    --arg storage_percent "$storage_percent" \
    --arg verdict "$verdict" \
    --argjson reasons "$reasons_json" \
    '{
      "instance": $instance,
      "state": $state,
      "config": $config,
      "multi_region": $multi_region,
      "node_count": $node_count,
      "processing_units": $processing_units,
      "database_count": $database_count,
      "cpu_high_priority_percent": (if $cpu_percent == "null" then null else ($cpu_percent | tonumber) end),
      "storage_percent_of_limit": (if $storage_percent == "null" then null else ($storage_percent | tonumber) end),
      "verdict": $verdict,
      "reasons": $reasons
    }')

  echo "$instance_summary" >> /tmp/health_summary_instances.jsonl

  if [ "$verdict" != "healthy" ]; then
    reasons_text=$(echo "$reasons_json" | jq -r 'join("; ")')
    severity=3
    printf '{"title":"Cloud Spanner instance `%s` health verdict: %s","details":"Instance `%s` in project `%s` rolled up to verdict %s. Reasons: %s.","severity":%s,"expected":"Instance should have a healthy verdict across state, CPU, and storage dimensions","actual":"Verdict is %s (%s)","next_steps":"Review the detailed instance-state, CPU-utilization, and storage-utilization task results for `%s` and remediate the flagged dimension(s).","instance":"%s"}\n' \
      "$instance_id" "$verdict" "$instance_id" "$GCP_PROJECT_ID" "$verdict" "$reasons_text" "$severity" "$verdict" "$reasons_text" "$instance_id" "$instance_id" >> /tmp/health_summary_issues.jsonl
  fi
done

if [ -s /tmp/health_summary_instances.jsonl ]; then
  instances_json=$(jq -s '.' /tmp/health_summary_instances.jsonl)
else
  instances_json="[]"
fi

jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson total_instances "$instance_count" \
  --argjson instances "$instances_json" \
  '{
    "project_id": $project_id,
    "total_instances": $total_instances,
    "instances": $instances
  }' > "$SUMMARY_FILE"

if [ -s /tmp/health_summary_issues.jsonl ]; then
  jq -s '.' /tmp/health_summary_issues.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/health_summary_instances.jsonl /tmp/health_summary_issues.jsonl

echo "Health summary generated. $(jq length "$OUTPUT_FILE") instance(s) flagged."
jq . "$SUMMARY_FILE"
