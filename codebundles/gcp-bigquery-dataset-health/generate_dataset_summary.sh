#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="dataset_summary.json"

echo "Generating BigQuery dataset health summary for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
dataset_count=$(echo "$datasets" | jq length)

total_tables=0
total_physical_bytes=0
total_logical_bytes=0
largest_tables="[]"
datasets_no_expiration=0
datasets_details="[]"

if [ "$dataset_count" -eq 0 ]; then
  echo "No datasets found."
  echo "{\"project_id\":\"$GCP_PROJECT_ID\",\"total_datasets\":0,\"total_tables\":0,\"total_storage_gb\":0,\"total_storage_tb\":0,\"datasets_no_expiration\":0,\"largest_tables\":[],\"datasets_details\":[]}" > "$OUTPUT_FILE"
  jq . "$OUTPUT_FILE"
  exit 0
fi

declare -a dataset_details_arr=()

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  
  ds_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null)
  default_expiration=$(echo "$ds_info" | jq -r '.defaultTableExpirationMs // empty')
  has_expiration=true
  if [ -z "$default_expiration" ] || [ "$default_expiration" = "null" ]; then
    has_expiration=false
  fi

  tables=$(bq --project_id "$GCP_PROJECT_ID" query --nouse_legacy_sql --format=json "SELECT COUNT(*) as table_count, COALESCE(SUM(total_physical_bytes), 0) as physical_bytes, COALESCE(SUM(total_logical_bytes), 0) as logical_bytes FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\` WHERE table_type = 'BASE TABLE' AND table_schema = '$dataset_id'" 2>/dev/null)

  table_count=$(echo "$tables" | jq -r '.[0].table_count // 0')
  physical_bytes=$(echo "$tables" | jq -r '.[0].physical_bytes // 0')
  logical_bytes=$(echo "$tables" | jq -r '.[0].logical_bytes // 0')

  echo "{\"dataset\":\"$dataset_id\",\"table_count\":$table_count,\"physical_bytes\":$physical_bytes,\"logical_bytes\":$logical_bytes,\"has_default_expiration\":$has_expiration}" >> /tmp/bq_dataset_summary_parts.$$.jsonl

  # Get top 5 largest tables for this dataset
  top_tables=$(bq --project_id "$GCP_PROJECT_ID" query --nouse_legacy_sql --format=json "SELECT table_name, ROUND(total_physical_bytes / POW(1024, 3), 2) as size_gb FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\` WHERE table_type = 'BASE TABLE' AND table_schema = '$dataset_id' ORDER BY total_physical_bytes DESC LIMIT 5" 2>/dev/null)
  
  echo "$top_tables" | jq -c '.[]' | while read -r t; do
    tn=$(echo "$t" | jq -r '.table_name')
    sg=$(echo "$t" | jq -r '.size_gb')
    echo "{\"dataset\":\"$dataset_id\",\"table\":\"$tn\",\"size_gb\":$sg}" >> /tmp/bq_dataset_largest.$$.jsonl
  done
done

# Aggregate results
if [ -f /tmp/bq_dataset_summary_parts.$$.jsonl ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ds_name=$(echo "$line" | jq -r '.dataset')
    tc=$(echo "$line" | jq -r '.table_count')
    pb=$(echo "$line" | jq -r '.physical_bytes')
    lb=$(echo "$line" | jq -r '.logical_bytes')
    he=$(echo "$line" | jq -r '.has_default_expiration')
    total_tables=$((total_tables + tc))
    total_physical_bytes=$((total_physical_bytes + pb))
    total_logical_bytes=$((total_logical_bytes + lb))
    if [ "$he" = "false" ]; then
      datasets_no_expiration=$((datasets_no_expiration + 1))
    fi
    dataset_details_arr+=("$line")
  done < /tmp/bq_dataset_summary_parts.$$.jsonl
  rm -f /tmp/bq_dataset_summary_parts.$$.jsonl
fi

total_storage_gb=$(python3 -c "print(f'{float($total_physical_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")
total_storage_tb=$(python3 -c "print(f'{float($total_physical_bytes) / (1024**4):.2f}')" 2>/dev/null || echo "0")

# Build largest tables list
largest_list="[]"
if [ -f /tmp/bq_dataset_largest.$$.jsonl ]; then
  largest_list=$(jq -s '.' /tmp/bq_dataset_largest.$$.jsonl 2>/dev/null || echo "[]")
  rm -f /tmp/bq_dataset_largest.$$.jsonl
fi

datasets_details_json=$(printf '%s\n' "${dataset_details_arr[@]}" | jq -s '.' 2>/dev/null || echo "[]")

summary=$(jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson total_datasets "$dataset_count" \
  --argjson total_tables "$total_tables" \
  --arg total_storage_gb "$total_storage_gb" \
  --arg total_storage_tb "$total_storage_tb" \
  --argjson datasets_no_expiration "$datasets_no_expiration" \
  --argjson largest_tables "$largest_list" \
  --argjson datasets_details "$datasets_details_json" \
  '{
    "project_id": $project_id,
    "total_datasets": $total_datasets,
    "total_tables": $total_tables,
    "total_storage_gb": ($total_storage_gb | tonumber),
    "total_storage_tb": ($total_storage_tb | tonumber),
    "datasets_no_expiration": $datasets_no_expiration,
    "largest_tables": $largest_tables,
    "datasets_details": $datasets_details
  }')

echo "$summary" > "$OUTPUT_FILE"
echo "Summary generated."
jq . "$OUTPUT_FILE"