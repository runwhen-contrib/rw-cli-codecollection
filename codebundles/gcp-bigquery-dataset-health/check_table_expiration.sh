#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="table_expiration_issues.json"

echo "Checking table expiration policies for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
dataset_count=$(echo "$datasets" | jq length)

if [ "$dataset_count" -eq 0 ]; then
  echo "No datasets found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  echo "Checking dataset: $dataset_id"

  ds_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null)
  default_expiration=$(echo "$ds_info" | jq -r '.defaultTableExpirationMs // .defaultPartitionExpirationMs // empty')

  if [ -z "$default_expiration" ] || [ "$default_expiration" = "null" ]; then
    echo "  Dataset $dataset_id has no default table expiration set."
    printf '{"title":"BigQuery dataset `%s` lacks default table expiration","details":"Dataset `%s` in project `%s` has no default table expiration set. Tables can grow unbounded without automatic cleanup.","severity":3,"next_steps":"Set a default table expiration on dataset `%s` using: bq update --default_table_expiration <seconds> `%s:%s`","expected":"Dataset should have a default table expiration policy","actual":"No default table expiration set","dataset":"%s","issue_type":"no_default_expiration"}\n' \
      "$dataset_id" "$dataset_id" "$GCP_PROJECT_ID" "$dataset_id" "$GCP_PROJECT_ID" "$dataset_id" "$dataset_id" >> "$OUTPUT_FILE"
  fi

  tables=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json "$dataset_id" 2>/dev/null || echo "[]")

  if [ "$(echo "$tables" | jq length)" -eq 0 ]; then
    echo "  No tables in dataset $dataset_id."
    continue
  fi

  echo "$tables" | jq -c '.[]' | while read -r table; do
    table_name=$(echo "$table" | jq -r '.tableReference.tableId')
    table_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id.$table_name" 2>/dev/null)
    expiration_time=$(echo "$table_info" | jq -r '.expirationTime // empty')

    if [ -z "$expiration_time" ] || [ "$expiration_time" = "null" ]; then
      echo "  Table $dataset_id.$table_name has no expiration."
      printf '{"title":"BigQuery table `%s.%s` lacks expiration timestamp","details":"Table `%s.%s` in project `%s` has no expiration timestamp set. This table will persist indefinitely unless manually cleaned up.","severity":4,"next_steps":"Consider setting an expiration for table `%s.%s` using: bq update --expiration <seconds> `%s:%s.%s`","expected":"Table should have an expiration timestamp","actual":"No expiration timestamp","dataset":"%s","table":"%s","issue_type":"no_table_expiration"}\n' \
        "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$GCP_PROJECT_ID" "$dataset_id" "$table_name" "$GCP_PROJECT_ID" "$dataset_id" "$table_name" "$dataset_id" "$table_name" >> "$OUTPUT_FILE"
    fi
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Expiration check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"