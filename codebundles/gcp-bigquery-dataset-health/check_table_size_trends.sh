#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${TABLE_SIZE_THRESHOLD_GB:=100}"
: "${TABLE_GROWTH_THRESHOLD_PERCENT:=50}"
: "${INCLUDE_STREAMING_BUFFER:=false}"

OUTPUT_FILE="table_size_issues.json"
issues_json='[]'

bq_query() {
  bq --project_id "$GCP_PROJECT_ID" query --nouse_legacy_sql --format=json "$1" 2>/dev/null || echo "[]"
}

echo "Analyzing table sizes for project: $GCP_PROJECT_ID"

current_size_query="SELECT table_catalog, table_schema, table_name, total_physical_bytes, total_logical_bytes, TIMESTAMP(creation_time) as creation_time FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\` WHERE table_type = 'BASE TABLE' AND table_catalog = '$GCP_PROJECT_ID'"

if [ "$INCLUDE_STREAMING_BUFFER" = "true" ]; then
  current_size_query="SELECT table_catalog, table_schema, table_name, total_physical_bytes, total_logical_bytes, TIMESTAMP(creation_time) as creation_time FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\` WHERE table_type = 'BASE TABLE' AND table_catalog = '$GCP_PROJECT_ID'"
fi

tables=$(bq_query "$current_size_query" 2>/dev/null)

if [ "$(echo "$tables" | jq length)" -eq 0 ]; then
  echo "No tables found or unable to query INFORMATION_SCHEMA."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

echo "$tables" | jq -c '.[]' | while read -r table; do
  table_name=$(echo "$table" | jq -r '.table_name')
  dataset_name=$(echo "$table" | jq -r '.table_schema')
  physical_bytes=$(echo "$table" | jq -r '.total_physical_bytes // 0')
  logical_bytes=$(echo "$table" | jq -r '.total_logical_bytes // 0')

  size_gb=$(awk "BEGIN {printf \"%.2f\", $physical_bytes / (1024^3)}")
  size_gb_logical=$(awk "BEGIN {printf \"%.2f\", $logical_bytes / (1024^3)}")

  if (( $(echo "$size_gb > $TABLE_SIZE_THRESHOLD_GB" | bc -l) )); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "BigQuery table \`$dataset_name.$table_name\` exceeds size threshold" \
      --arg details "Table \`$dataset_name.$table_name\` in project \`$GCP_PROJECT_ID\` uses ${size_gb}GB physical storage (threshold: ${TABLE_SIZE_THRESHOLD_GB}GB). Logical size: ${size_gb_logical}GB." \
      --arg severity "3" \
      --arg next_steps "Consider partitioning the table, setting an expiration, or archiving old data. Review table schema and usage patterns." \
      --arg expected "Table size should be below ${TABLE_SIZE_THRESHOLD_GB}GB" \
      --arg actual "Table size is ${size_gb}GB" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_name,
         "table": $table_name
       }]')
  fi
done

# bc might not be available everywhere, use awk for the main checks
tables_final=$(echo "$tables" | jq -c '.[]')
output_json='[]'
while IFS= read -r table; do
  [ -z "$table" ] && continue
  table_name=$(echo "$table" | jq -r '.table_name')
  dataset_name=$(echo "$table" | jq -r '.table_schema')
  physical_bytes=$(echo "$table" | jq -r '.total_physical_bytes // 0')
  logical_bytes=$(echo "$table" | jq -r '.total_logical_bytes // 0')

  size_gb=$(python3 -c "print(f'{float($physical_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")

  if python3 -c "exit(0 if float($size_gb) > float($TABLE_SIZE_THRESHOLD_GB) else 1)" 2>/dev/null; then
    output_json=$(echo "$output_json" | jq \
      --arg title "BigQuery table \`$dataset_name.$table_name\` exceeds size threshold" \
      --arg details "Table \`$dataset_name.$table_name\` in project \`$GCP_PROJECT_ID\` uses ${size_gb}GB physical storage (threshold: ${TABLE_SIZE_THRESHOLD_GB}GB)." \
      --arg severity "3" \
      --arg next_steps "Consider partitioning the table, setting an expiration, or archiving old data. Review table schema and usage patterns." \
      --arg expected "Table size should be below ${TABLE_SIZE_THRESHOLD_GB}GB" \
      --arg actual "Table size is ${size_gb}GB" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_name,
         "table": $table_name
       }]')
  fi
done <<< "$tables_final"

echo "$output_json" > "$OUTPUT_FILE"
echo "Analysis completed. Found $(echo "$output_json" | jq length) table size issues."
jq . "$OUTPUT_FILE"