#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="table_expiration_issues.json"
issues_json='[]'

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
    echo "{\"title\":\"BigQuery dataset \\\`$dataset_id\\\` lacks default table expiration\",\"details\":\"Dataset \\\`$dataset_id\\\` in project \\\`$GCP_PROJECT_ID\\\` has no default table expiration set. Tables in this dataset can grow unbounded without automatic cleanup.\",\"severity\":3,\"next_steps\":\"Set a default table expiration on dataset \\\`$dataset_id\\\` using: bq update --default_table_expiration <seconds> \\\`$GCP_PROJECT_ID:$dataset_id\\\`\",\"expected\":\"Dataset should have a default table expiration policy\",\"actual\":\"No default table expiration set\",\"dataset\":\"$dataset_id\",\"issue_type\":\"no_default_expiration\"}" >> "$OUTPUT_FILE"
  fi

  tables=$(bq --project_id "$GCP_PROJECT_ID" query --nouse_legacy_sql --format=json "SELECT table_name, table_type, TIMESTAMP(creation_time) as creation_time, expiration_time, ddl FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\` WHERE table_type = 'BASE TABLE' AND table_schema = '$dataset_id'" 2>/dev/null)
  
  if [ "$(echo "$tables" | jq length)" -eq 0 ]; then
    echo "  No tables in dataset $dataset_id."
    continue
  fi

  echo "$tables" | jq -c '.[]' | while read -r table; do
    table_name=$(echo "$table" | jq -r '.table_name')
    expiration_time=$(echo "$table" | jq -r '.expiration_time // empty')

    if [ -z "$expiration_time" ] || [ "$expiration_time" = "null" ]; then
      echo "  Table $dataset_id.$table_name has no expiration."
      echo "{\"title\":\"BigQuery table \\\`$dataset_id.$table_name\\\` lacks expiration timestamp\",\"details\":\"Table \\\`$dataset_id.$table_name\\\` in project \\\`$GCP_PROJECT_ID\\\` has no expiration timestamp set. This table will persist indefinitely unless manually cleaned up.\",\"severity\":4,\"next_steps\":\"Consider setting an expiration for table \\\`$dataset_id.$table_name\\\` using: bq update --expiration <seconds> \\\`$GCP_PROJECT_ID:$dataset_id.$table_name\\\`\",\"expected\":\"Table should have an expiration timestamp\",\"actual\":\"No expiration timestamp\",\"dataset\":\"$dataset_id\",\"table\":\"$table_name\",\"issue_type\":\"no_table_expiration\"}" >> "$OUTPUT_FILE"
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