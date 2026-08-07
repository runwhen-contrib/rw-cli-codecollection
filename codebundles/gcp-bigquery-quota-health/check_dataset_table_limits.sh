#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${DATASET_TABLE_THRESHOLD:=80}"

OUTPUT_FILE="dataset_table_limit_issues.json"

# GCP limits
MAX_TABLES_PER_DATASET=10000
MAX_DATASETS_PER_PROJECT=10000

echo "Analyzing dataset and table counts for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
dataset_count=$(echo "$datasets" | jq length 2>/dev/null || echo 0)

if [ "$dataset_count" -eq 0 ]; then
  echo "No datasets found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

# For each dataset, count tables; flag datasets approaching the per-dataset cap.
echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  tables=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json "$dataset_id" 2>/dev/null || echo "[]")
  table_count=$(echo "$tables" | jq 'length' 2>/dev/null || echo 0)

  dataset_usage_pct=$(python3 -c "print(f'{float($table_count) / $MAX_TABLES_PER_DATASET * 100:.2f}')" 2>/dev/null || echo "0")

  if python3 -c "import sys; sys.exit(0 if float('$dataset_usage_pct') >= float('$DATASET_TABLE_THRESHOLD') else 1)" 2>/dev/null; then
    printf '{"title":"BigQuery dataset `%s` approaching table limit","details":"Dataset `%s` in project `%s` has %s tables, which is %s%% of the %s table per-dataset limit.","expected":"Table count should stay below %s%% of the %s table limit","actual":"Dataset has %s tables (%s%% of limit)","severity":3,"next_steps":"Shard data into additional datasets, apply partitioning, or consider separate projects for capacity growth.","dataset":"%s","table_count":%s}\n' \
      "$dataset_id" "$dataset_id" "$GCP_PROJECT_ID" "$table_count" "$dataset_usage_pct" "$MAX_TABLES_PER_DATASET" "$DATASET_TABLE_THRESHOLD" "$MAX_TABLES_PER_DATASET" "$table_count" "$dataset_usage_pct" "$dataset_id" "$table_count" >> "$OUTPUT_FILE"
  fi
done

# Check the per-project dataset cap.
project_usage_pct=$(python3 -c "print(f'{float($dataset_count) / $MAX_DATASETS_PER_PROJECT * 100:.2f}')" 2>/dev/null || echo "0")
if python3 -c "import sys; sys.exit(0 if float('$project_usage_pct') >= float('$DATASET_TABLE_THRESHOLD') else 1)" 2>/dev/null; then
  printf '{"title":"BigQuery project `%s` approaching dataset limit","details":"BigQuery project `%s` has %s datasets, which is %s%% of the %s dataset per-project limit.","expected":"Dataset count should stay below %s%% of the %s dataset limit","actual":"Project has %s datasets (%s%% of limit)","severity":3,"next_steps":"Consolidate datasets or request a quota increase for the project dataset limit.","dataset":"<project>","table_count":%s}\n' \
    "$GCP_PROJECT_ID" "$GCP_PROJECT_ID" "$dataset_count" "$project_usage_pct" "$MAX_DATASETS_PER_PROJECT" "$DATASET_TABLE_THRESHOLD" "$MAX_DATASETS_PER_PROJECT" "$dataset_count" "$project_usage_pct" "$dataset_count" >> "$OUTPUT_FILE"
fi

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Dataset/table limit analysis completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"
