#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="table_optimization_issues.json"

echo "Checking table partitioning and clustering for project: $GCP_PROJECT_ID"

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

    has_partition=$(echo "$table_info" | jq -r 'if .timePartitioning or .rangePartitioning then "true" else "false" end')
    has_clustering=$(echo "$table_info" | jq -r 'if .clustering then "true" else "false" end')

    size_gb=$(python3 -c "print(f'{float($num_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")

    if [ "$has_partition" = "false" ]; then
      printf '{"title":"Large table `%s.%s` lacks partitioning","details":"Table `%s.%s` in project `%s` is %sGB but has no partitioning configured. Partitioning can improve query performance and reduce costs.","severity":4,"next_steps":"Consider adding partitioning to table `%s.%s` based on a date/timestamp column or integer range.","expected":"Large tables should be partitioned for performance and cost","actual":"Table lacks partitioning","dataset":"%s","table":"%s","size_gb":%s,"issue_type":"missing_partitioning"}\n' \
        "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$GCP_PROJECT_ID" "$size_gb" "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$size_gb" >> "$OUTPUT_FILE"
    fi

    if [ "$has_clustering" = "false" ] && [ "$has_partition" = "true" ]; then
      printf '{"title":"Table `%s.%s` could benefit from clustering","details":"Table `%s.%s` in project `%s` is %sGB and has partitioning but no clustering. Clustering can further improve query performance.","severity":4,"next_steps":"Consider adding clustering to table `%s.%s` on commonly filtered columns.","expected":"Large partitioned tables should also be clustered","actual":"Table lacks clustering","dataset":"%s","table":"%s","size_gb":%s,"issue_type":"missing_clustering"}\n' \
        "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$GCP_PROJECT_ID" "$size_gb" "$dataset_id" "$table_name" "$dataset_id" "$table_name" "$size_gb" >> "$OUTPUT_FILE"
    fi
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Optimization check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"