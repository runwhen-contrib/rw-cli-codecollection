#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${TABLE_SIZE_THRESHOLD_GB:=100}"

OUTPUT_FILE="table_size_issues.json"

echo "Analyzing table sizes for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$datasets" | jq length)" -eq 0 ]; then
  echo "No datasets found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')

  tables=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json "$dataset_id" 2>/dev/null || echo "[]")

  if [ "$(echo "$tables" | jq length)" -eq 0 ]; then
    continue
  fi

  echo "$tables" | jq -c '.[]' | while read -r table; do
    table_name=$(echo "$table" | jq -r '.tableReference.tableId')
    table_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id.$table_name" 2>/dev/null)
    num_bytes=$(echo "$table_info" | jq -r '.numBytes // 0')

    if [ "$num_bytes" = "null" ] || [ "$num_bytes" = "0" ]; then
      continue
    fi

    size_gb=$(python3 -c "print(f'{float($num_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")

    if python3 -c "exit(0 if float($size_gb) > float($TABLE_SIZE_THRESHOLD_GB) else 1)" 2>/dev/null; then
      printf '{"title":"BigQuery table `%s.%s` exceeds size threshold","details":"Table `%s.%s` in project `%s` uses %sGB physical storage (threshold: %sGB).","severity":3,"next_steps":"Consider partitioning the table, setting an expiration, or archiving old data.","expected":"Table size should be below %sGB","actual":"Table size is %sGB","dataset":"%s","table":"%s"}\n' \
        "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$GCP_PROJECT_ID" "$size_gb" "$TABLE_SIZE_THRESHOLD_GB" "$TABLE_SIZE_THRESHOLD_GB" "$size_gb" "$dataset_id" "$table_name" >> "$OUTPUT_FILE"
    fi
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Analysis completed. Found $(jq length "$OUTPUT_FILE") table size issues."
jq . "$OUTPUT_FILE"