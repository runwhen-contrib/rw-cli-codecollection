#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   STORAGE_UTILIZATION_THRESHOLD  (default 75)   -- percent of limit that triggers an issue
#   STORAGE_LIMIT_GB_PER_NODE      (default 4096) -- Spanner storage limit per node / per
#                                                     1000 processing units, in GB (~4 TB)
#
# This script:
#   1) Lists all Cloud Spanner instances in the project
#   2) Derives each instance's storage LIMIT from its node_count / processing_units
#      (never hardcoded) using ~4 TB per node (1000 processing units == 1 node)
#   3) Reads storage used from Cloud Monitoring
#      (spanner.googleapis.com/instance/storage/used_bytes)
#   4) Flags instances approaching the derived limit, which can block writes
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STORAGE_UTILIZATION_THRESHOLD:=75}"
: "${STORAGE_LIMIT_GB_PER_NODE:=4096}"

OUTPUT_FILE="storage_utilization_issues.json"

echo "Checking Cloud Spanner storage utilization for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")

> /tmp/storage_util_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')
  node_count=$(echo "$inst" | jq -r '.nodeCount // 0')
  processing_units=$(echo "$inst" | jq -r '.processingUnits // 0')

  # Node-equivalent: 1000 processing units == 1 node. Use whichever is set.
  node_equivalent=$(python3 -c "
node_count = $node_count
pu = $processing_units
ne = node_count if node_count > 0 else (pu / 1000.0 if pu > 0 else 0)
print(ne if ne > 0 else 0.1)
" 2>/dev/null || echo "0.1")

  limit_gb=$(python3 -c "print(f'{float($node_equivalent) * float($STORAGE_LIMIT_GB_PER_NODE):.2f}')" 2>/dev/null || echo "$STORAGE_LIMIT_GB_PER_NODE")

  metric_filter="metric.type=\"spanner.googleapis.com/instance/storage/used_bytes\" AND resource.labels.instance_id=\"$instance_id\""

  series=$(gcloud monitoring time-series list \
    --project="$GCP_PROJECT_ID" \
    --filter="$metric_filter" \
    --interval-start-time="$start_time" \
    --interval-end-time="$end_time" \
    --format=json 2>/dev/null || echo "[]")

  used_bytes=$(echo "$series" | jq '[.[].points[]?.value | (.doubleValue // .int64Value // empty)] | if length > 0 then (.[0] | tonumber) else -1 end' 2>/dev/null || echo "-1")

  if [ "$used_bytes" = "-1" ] || [ -z "$used_bytes" ]; then
    echo "No storage utilization data available for instance $instance_id; skipping."
    continue
  fi

  used_gb=$(python3 -c "print(f'{float($used_bytes) / (1000**3):.2f}')" 2>/dev/null || echo "0")
  percent_used=$(python3 -c "print(f'{(float($used_gb) / float($limit_gb) * 100):.2f}' if float($limit_gb) > 0 else '0')" 2>/dev/null || echo "0")

  echo "Instance $instance_id: used=${used_gb}GB limit=${limit_gb}GB (${percent_used}%) node_equivalent=$node_equivalent"

  if python3 -c "exit(0 if float($percent_used) > float($STORAGE_UTILIZATION_THRESHOLD) else 1)" 2>/dev/null; then
    severity=3
    if python3 -c "exit(0 if float($percent_used) > 90 else 1)" 2>/dev/null; then
      severity=2
    fi
    printf '{"title":"Cloud Spanner instance `%s` approaching storage limit","details":"Instance `%s` uses %sGB of a derived %sGB limit (%s%% -- node_count=%s, processing_units=%s), above the %s%% threshold.","severity":%s,"expected":"Storage utilization should stay below %s%% of the node/PU-derived limit","actual":"Storage utilization is %s%% of the derived limit","next_steps":"Add nodes/processing units (`gcloud spanner instances update %s --processing-units=<value> --project=%s`) or reduce stored data (TTL/archival) before the instance hits its storage limit, which blocks writes.","instance":"%s"}\n' \
      "$instance_id" "$instance_id" "$used_gb" "$limit_gb" "$percent_used" "$node_count" "$processing_units" "$STORAGE_UTILIZATION_THRESHOLD" "$severity" "$STORAGE_UTILIZATION_THRESHOLD" "$percent_used" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" >> /tmp/storage_util_parts.jsonl
  fi
done

if [ -s /tmp/storage_util_parts.jsonl ]; then
  jq -s '.' /tmp/storage_util_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/storage_util_parts.jsonl

echo "Storage utilization check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
