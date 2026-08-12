#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STORAGE_QUOTA_THRESHOLD:=85}"

OUTPUT_FILE="storage_quota_issues.json"

echo "Analyzing storage quota for project: $GCP_PROJECT_ID"

logical_bytes=0
physical_bytes=0

dataset_list=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")

if [ -z "$dataset_list" ]; then
  echo "No datasets found or bq ls failed."
  echo "[]" > "$OUTPUT_FILE"
  echo "Storage quota analysis completed — no datasets to check."
  exit 0
fi

echo "  Datasets found: $(echo "$dataset_list" | wc -l)"

while read -r dataset; do
  [ -z "$dataset" ] && continue
  report=$(bq --project_id "$GCP_PROJECT_ID" query --use_legacy_sql=false --format=json \
    "SELECT SUM(TOTAL_LOGICAL_BYTES) AS logical_bytes, SUM(TOTAL_PHYSICAL_BYTES) AS physical_bytes FROM \`$GCP_PROJECT_ID.$dataset.INFORMATION_SCHEMA.TABLE_STORAGE\`" \
    2>/dev/null || echo "")
  l=$(echo "$report" | jq -r '.[0].logical_bytes // 0' 2>/dev/null || echo 0)
  p=$(echo "$report" | jq -r '.[0].physical_bytes // 0' 2>/dev/null || echo 0)
  l=${l:-0}; p=${p:-0}
  logical_bytes=$((logical_bytes + l))
  physical_bytes=$((physical_bytes + p))
  echo "  Dataset $dataset: $(python3 -c "print(f'{float($l)/(1024**3):.2f}')" 2>/dev/null || echo 0) GB logical"
done <<< "$dataset_list"

storage_quota_bytes=${BIGQUERY_STORAGE_QUOTA_BYTES:-10995116277760}

if [ "$logical_bytes" -eq 0 ] && [ "$physical_bytes" -eq 0 ]; then
  echo "No storage data reported for project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"

  echo ""
  echo "=== LLM Context ==="
  echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=$GCP_PROJECT_ID"
  echo "Storage Quota Threshold: ${STORAGE_QUOTA_THRESHOLD}%"
  echo "Default Quota: 10 TB logical storage for on-demand projects"
  exit 0
fi

storage_quota_gb=$(python3 -c "print(f'{float($storage_quota_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "10240")
logical_gb=$(python3 -c "print(f'{float($logical_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")
physical_gb=$(python3 -c "print(f'{float($physical_bytes) / (1024**3):.2f}')" 2>/dev/null || echo "0")
usage_pct=$(python3 -c "print(f'{float($logical_bytes) / float($storage_quota_bytes) * 100:.2f}')" 2>/dev/null || echo "0")

echo ""
echo "Storage Summary:"
echo "  Logical storage: ${logical_gb} GB"
echo "  Physical storage: ${physical_gb} GB"
echo "  Storage quota: ${storage_quota_gb} GB (${storage_quota_bytes} bytes)"
echo "  Usage: ${usage_pct}% of quota (threshold: ${STORAGE_QUOTA_THRESHOLD}%)"

if python3 -c "import sys; sys.exit(0 if float('$usage_pct') >= float('$STORAGE_QUOTA_THRESHOLD') else 1)" 2>/dev/null; then
  if python3 -c "import sys; sys.exit(0 if float('$usage_pct') >= 95 else 1)" 2>/dev/null; then
    severity="3"
  else
    severity="2"
  fi
  jq -n \
    --arg title "BigQuery storage quota nearly exhausted for project \`$GCP_PROJECT_ID\`" \
    --arg details "BigQuery project \`$GCP_PROJECT_ID\` is using ${usage_pct}% of its storage quota (${logical_gb} GB logical / ${physical_gb} GB physical of ${storage_quota_gb} GB). Threshold is ${STORAGE_QUOTA_THRESHOLD}%." \
    --arg expected "Storage usage should remain below ${STORAGE_QUOTA_THRESHOLD}% of the project quota" \
    --arg actual "Storage usage is ${usage_pct}% of quota (${logical_gb} GB logical)" \
    --arg severity "$severity" \
    --arg next_steps "Delete unused tables and datasets, set table expiration policies, partition large tables, or request a storage quota increase from GCP support." \
    '[{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}]' > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo ""
echo "=== LLM Context ==="
echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=$GCP_PROJECT_ID"
echo "Storage Quota Threshold: ${STORAGE_QUOTA_THRESHOLD}%"
echo "Suggested Follow-up Queries:"
echo "  # Show per-dataset storage breakdown"
echo "  SELECT table_schema AS dataset, SUM(TOTAL_LOGICAL_BYTES) / POW(1024,3) AS logical_gb,"
echo "         SUM(TOTAL_PHYSICAL_BYTES) / POW(1024,3) AS physical_gb"
echo "  FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.TABLE_STORAGE\`"
echo "  GROUP BY dataset ORDER BY logical_gb DESC;"
echo ""
echo "  # Find largest tables"
echo "  SELECT table_schema AS dataset, table_name, TOTAL_LOGICAL_BYTES / POW(1024,3) AS size_gb"
echo "  FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.TABLE_STORAGE\`"
echo "  ORDER BY size_gb DESC LIMIT 20;"

echo "Storage quota analysis completed."