#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="dataset_summary.json"

echo "Generating BigQuery dataset health summary for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
dataset_count=$(echo "$datasets" | jq length)

if [ "$dataset_count" -eq 0 ]; then
  echo "No datasets found."
  printf '{"project_id":"%s","total_datasets":0,"total_tables":0,"total_storage_gb":0,"total_storage_tb":0,"datasets_no_expiration":0,"largest_tables":[],"datasets_details":[]}\n' "$GCP_PROJECT_ID" > "$OUTPUT_FILE"
  jq . "$OUTPUT_FILE"
  exit 0
fi

> /tmp/bq_summary_parts.jsonl
> /tmp/bq_largest_tables.jsonl

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')

  ds_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null)
  default_expiration=$(echo "$ds_info" | jq -r '.defaultTableExpirationMs // empty')
  has_expiration=true
  if [ -z "$default_expiration" ] || [ "$default_expiration" = "null" ]; then
    has_expiration=false
  fi

  tables=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json "$dataset_id" 2>/dev/null || echo "[]")
  if [ -z "$tables" ]; then
    tables="[]"
  fi
  table_count=$(echo "$tables" | jq 'if type == "array" then length else 0 end')
  physical_bytes=0

  echo "$tables" | jq -c '.[]' | while read -r table; do
    table_name=$(echo "$table" | jq -r '.tableReference.tableId')
    table_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id.$table_name" 2>/dev/null)
    num_bytes=$(echo "$table_info" | jq -r '.numBytes // 0')

    if [ "$num_bytes" != "null" ] && [ "$num_bytes" != "0" ]; then
      size_gb=$(python3 -c "print(f'{float($num_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")
      printf '{"dataset":"%s","table":"%s","size_gb":%s}\n' "$dataset_id" "$table_name" "$size_gb" >> /tmp/bq_largest_tables.jsonl
    fi
  done

  printf '{"dataset":"%s","table_count":%s,"has_default_expiration":%s}\n' "$dataset_id" "$table_count" "$has_expiration" >> /tmp/bq_summary_parts.jsonl
  echo "  Dataset $dataset_id: $table_count tables, expiration=$has_expiration"
done

total_tables=0
datasets_no_expiration=0
dataset_details=()

while IFS= read -r line; do
  [ -z "$line" ] && continue
  tc=$(echo "$line" | jq -r '.table_count')
  he=$(echo "$line" | jq -r '.has_default_expiration')
  ds_name=$(echo "$line" | jq -r '.dataset')
  total_tables=$((total_tables + tc))
  if [ "$he" = "false" ]; then
    datasets_no_expiration=$((datasets_no_expiration + 1))
  fi
  dataset_details+=("$line")
done < /tmp/bq_summary_parts.jsonl

datasets_details_json=$(printf '%s\n' "${dataset_details[@]}" | jq -s '.' 2>/dev/null || echo "[]")

largest_list="[]"
if [ -s /tmp/bq_largest_tables.jsonl ]; then
  largest_list=$(jq -s '.' /tmp/bq_largest_tables.jsonl 2>/dev/null || echo "[]")
fi

summary=$(jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson total_datasets "$dataset_count" \
  --argjson total_tables "$total_tables" \
  --argjson datasets_no_expiration "$datasets_no_expiration" \
  --argjson largest_tables "$largest_list" \
  --argjson datasets_details "$datasets_details_json" \
  '{
    "project_id": $project_id,
    "total_datasets": $total_datasets,
    "total_tables": $total_tables,
    "total_storage_gb": 0,
    "total_storage_tb": 0,
    "datasets_no_expiration": $datasets_no_expiration,
    "largest_tables": $largest_tables,
    "datasets_details": $datasets_details
  }')

echo "$summary" > "$OUTPUT_FILE"
rm -f /tmp/bq_summary_parts.jsonl /tmp/bq_largest_tables.jsonl
echo "Summary generated."
jq . "$OUTPUT_FILE"