#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="quota_summary.json"

echo "Generating BigQuery quota health summary for project: $GCP_PROJECT_ID"

# -----------------------------------------------------------------------------
# Slot capacity (reservation based)
# -----------------------------------------------------------------------------
admin_project="${BIGQUERY_ADMIN_PROJECT:-$GCP_PROJECT_ID}"
location="${BIGQUERY_LOCATION:-US}"

capacity_slots=0
reservation_json=$(gcloud bigquery reservations list \
  --project="$admin_project" \
  --location="$location" \
  --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$reservation_json" | jq length)" -gt 0 ]; then
  capacity_slots=$(echo "$reservation_json" | jq '[.[].slot_capacity // 0] | add')
fi

# -----------------------------------------------------------------------------
# Storage usage via INFORMATION_SCHEMA.TABLE_STORAGE
# -----------------------------------------------------------------------------
logical_bytes=0
for dataset in $(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null); do
  report=$(bq --project_id "$GCP_PROJECT_ID" query --use_legacy_sql=false --format=json \
    "SELECT SUM(TOTAL_LOGICAL_BYTES) AS logical_bytes FROM \`$GCP_PROJECT_ID.$dataset.INFORMATION_SCHEMA.TABLE_STORAGE\`" \
    2>/dev/null || echo "")
  l=$(echo "$report" | jq -r '.[0].logical_bytes // 0' 2>/dev/null); l=${l:-0}
  logical_bytes=$((logical_bytes + l))
done
storage_quota_bytes=${BIGQUERY_STORAGE_QUOTA_BYTES:-10995116277760}
storage_usage_pct=$(python3 -c "print(f'{float($logical_bytes) / float($storage_quota_bytes) * 100:.2f}')" 2>/dev/null || echo "0")

# -----------------------------------------------------------------------------
# Daily query count
# -----------------------------------------------------------------------------
today=$(date -u +%Y-%m-%d)
query_count=$(bq --project_id "$GCP_PROJECT_ID" query --use_legacy_sql=false --format=json \
  "SELECT COUNT(*) AS cnt FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\` WHERE creation_time >= TIMESTAMP('$today') AND job_type = 'QUERY'" \
  2>/dev/null | jq -r '.[0].cnt // 0' 2>/dev/null)
query_count=${query_count:-0}

# -----------------------------------------------------------------------------
# Dataset and table counts
# -----------------------------------------------------------------------------
datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
dataset_count=$(echo "$datasets" | jq length 2>/dev/null || echo 0)
table_count=0
for dataset in $(echo "$datasets" | jq -r '.[].datasetReference.datasetId' 2>/dev/null); do
  tc=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json "$dataset" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  table_count=$((table_count + tc))
done

logical_gb=$(python3 -c "print(f'{float($logical_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")

summary=$(jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson capacity_slots "$capacity_slots" \
  --arg logical_storage_gb "$logical_gb" \
  --arg storage_usage_pct "$storage_usage_pct" \
  --argjson daily_query_count "$query_count" \
  --argjson total_datasets "$dataset_count" \
  --argjson total_tables "$table_count" \
  '{
    "project_id": $project_id,
    "slot_capacity_slots": $capacity_slots,
    "logical_storage_gb": ($logical_storage_gb | tonumber),
    "storage_usage_percent": ($storage_usage_pct | tonumber),
    "daily_query_count": $daily_query_count,
    "total_datasets": $total_datasets,
    "total_tables": $total_tables
  }')

echo "$summary" > "$OUTPUT_FILE"
echo "Summary generated."
jq . "$OUTPUT_FILE"
