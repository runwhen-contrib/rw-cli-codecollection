#!/usr/bin/env bash
set -euo pipefail

GCP_PROJECT_ID="${1:?Usage: $0 <GCP_PROJECT_ID> [DATASET] [SA_KEY_FILE]}"
DATASET="${2:-bq_job_health_test}"
SA_KEY_FILE="${3:-}"

echo "=== Submitting test BigQuery jobs for project: $GCP_PROJECT_ID ==="

if [ -n "$SA_KEY_FILE" ] && [ -f "$SA_KEY_FILE" ]; then
  echo "Authenticating with service account key: $SA_KEY_FILE"
  gcloud auth activate-service-account --key-file="$SA_KEY_FILE" --project="$GCP_PROJECT_ID" || true
elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  echo "Authenticating with GOOGLE_APPLICATION_CREDENTIALS: $GOOGLE_APPLICATION_CREDENTIALS"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --project="$GCP_PROJECT_ID" || true
fi

TOKEN=$(gcloud auth print-access-token)
API_BASE="https://bigquery.googleapis.com/bigquery/v2/projects/$GCP_PROJECT_ID"

submit_job() {
  local label="$1"
  local query="$2"
  local expect_success="$3"
  echo "[$label] Submitting job..."
  local response
  local http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"$query\", \"useLegacySql\": false}" \
    "${API_BASE}/jobs")
  http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | sed '$d')
  local state=$(echo "$body" | jq -r '.status.state // "UNKNOWN"')
  local job_id=$(echo "$body" | jq -r '.jobReference.jobId // "N/A"')
  if [ "$expect_success" = "true" ]; then
    echo "  Job $job_id submitted, state: $state"
  else
    echo "  Job $job_id submitted, state: $state (expected: DONE with error)"
  fi
}

# -- Successful jobs via bq query (reliable for valid queries) --
run_success() {
  local label="$1"
  echo "[SUCCESS:$label] Running valid query..."
  bq query --project_id="$GCP_PROJECT_ID" --use_legacy_sql=false \
    "SELECT 1 AS value, '$label' AS label, CURRENT_TIMESTAMP() AS ts" \
    > /dev/null 2>&1 || echo "  (warning: query returned non-zero)"
}

run_success "valid_select_1"
run_success "valid_select_2"
run_success "valid_select_3"
run_success "valid_select_4"

# -- Failed jobs via REST API (bypasses bq client-side validation) --
echo ""
echo "--- Submitting failure injection jobs (REST API to ensure job creation) ---"

# invalidQuery: bad column on valid table (will fail server-side)
submit_job "bad_column_invalidQuery" \
  "SELECT nonexistent_column, another_fake FROM \`${GCP_PROJECT_ID}.${DATASET}.test_data\`" \
  "false"

# invalidQuery: bad SQL syntax  
submit_job "bad_syntax_invalidQuery" \
  "SELECTT * FORM nowhere IMAGINARY TABLE" \
  "false"

# notFound: nonexistent table in valid dataset
submit_job "missing_table_notFound" \
  "SELECT * FROM \`${GCP_PROJECT_ID}.${DATASET}.nonexistent_table_abc123\`" \
  "false"

# notFound: nonexistent dataset
submit_job "missing_dataset_notFound" \
  "SELECT * FROM \`${GCP_PROJECT_ID}.nonexistent_ds_xyz789.some_table\`" \
  "false"

echo ""
echo "=== Done. Submitted 8 test jobs (4 success + 4 failure via REST API) ==="
echo "  Expected job mix: 50% success rate (below default 95% threshold)"
echo "  Expected error categories: invalidQuery (2), notFound (2)"
echo ""
echo "NOTE: Jobs submitted via REST API are asynchronous. Wait a few seconds"
echo "for them to complete before running the codebundle checks."
echo ""
echo "Run the codebundle with defaults to see issues, or override thresholds:"
echo "  SUCCESS_RATE_THRESHOLD=50  # to see no success_rate issue"
echo "  JOB_LOOKBACK_HOURS=1       # ensure jobs are within window"
