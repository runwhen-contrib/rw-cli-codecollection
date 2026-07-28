#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="table_optimization_issues.json"
issues_json='[]'

echo "Checking table partitioning and clustering for project: $GCP_PROJECT_ID"

# Query for large tables (> 1 GB) and their partitioning/clustering status
optimization_query="SELECT 
  table_catalog, table_schema, table_name, 
  ROUND(total_physical_bytes / POW(1024, 3), 2) AS size_gb,
  ROUND(total_logical_bytes / POW(1024, 3), 2) AS logical_size_gb,
  TIMESTAMP(creation_time) AS creation_time
FROM \`$GCP_PROJECT_ID.region-US.INFORMATION_SCHEMA.TABLES\`
WHERE table_type = 'BASE TABLE'
  AND table_catalog = '$GCP_PROJECT_ID'
  AND total_physical_bytes > 1073741824  -- > 1 GB
ORDER BY total_physical_bytes DESC"

tables=$(bq --project_id "$GCP_PROJECT_ID" query --nouse_legacy_sql --format=json "$optimization_query" 2>/dev/null || echo "[]")

if [ "$(echo "$tables" | jq length)" -eq 0 ]; then
  echo "No large tables (> 1 GB) found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$tables" | jq -c '.[]' | while read -r table; do
  table_name=$(echo "$table" | jq -r '.table_name')
  dataset_name=$(echo "$table" | jq -r '.table_schema')
  size_gb=$(echo "$table" | jq -r '.size_gb')

  # Check if table has partitioning or clustering
  ddl_info=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_name.$table_name" 2>/dev/null)
  
  has_partition=false
  has_cluster=false
  
  time_partitioning=$(echo "$ddl_info" | jq '.timePartitioning // empty')
  range_partitioning=$(echo "$ddl_info" | jq '.rangePartitioning // empty')
  clustering=$(echo "$ddl_info" | jq '.clustering // empty')
  
  if [ -n "$time_partitioning" ] && [ "$time_partitioning" != "null" ]; then
    has_partition=true
  fi
  if [ -n "$range_partitioning" ] && [ "$range_partitioning" != "null" ]; then
    has_partition=true
  fi
  if [ -n "$clustering" ] && [ "$clustering" != "null" ]; then
    has_cluster=true
  fi

  issues=()
  
  if [ "$has_partition" = false ]; then
    echo "{\"title\":\"Large table \\\`$dataset_name.$table_name\\\` lacks partitioning\",\"details\":\"Table \\\`$dataset_name.$table_name\\\` in project \\\`$GCP_PROJECT_ID\\\` is ${size_gb}GB but has no partitioning configured. Partitioning can improve query performance and reduce costs.\",\"severity\":4,\"next_steps\":\"Consider adding partitioning to table \\\`$dataset_name.$table_name\\\` based on a date/timestamp column or integer range. Use: CREATE OR REPLACE TABLE with PARTITION BY clause.\",\"expected\":\"Large tables should be partitioned for performance and cost\",\"actual\":\"Table lacks partitioning\",\"dataset\":\"$dataset_name\",\"table\":\"$table_name\",\"size_gb\":$size_gb,\"issue_type\":\"missing_partitioning\"}" >> "$OUTPUT_FILE"
  fi

  if [ "$has_cluster" = false ] && [ "$has_partition" = true ]; then
    echo "{\"title\":\"Table \\\`$dataset_name.$table_name\\\` could benefit from clustering\",\"details\":\"Table \\\`$dataset_name.$table_name\\\` in project \\\`$GCP_PROJECT_ID\\\` is ${size_gb}GB and has partitioning but no clustering. Clustering can further improve query performance on filtered columns.\",\"severity\":4,\"next_steps\":\"Consider adding clustering to table \\\`$dataset_name.$table_name\\\` on commonly filtered columns using: CREATE OR REPLACE TABLE with CLUSTER BY clause.\",\"expected\":\"Large partitioned tables should also be clustered\",\"actual\":\"Table lacks clustering\",\"dataset\":\"$dataset_name\",\"table\":\"$table_name\",\"size_gb\":$size_gb,\"issue_type\":\"missing_clustering\"}" >> "$OUTPUT_FILE"
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Optimization check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"