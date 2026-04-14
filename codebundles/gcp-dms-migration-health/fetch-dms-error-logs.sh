#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Bounded Cloud Logging query for DMS / datamigration when unhealthy jobs exist.
# No-op when dms_flagged_jobs.txt is empty.
# Env: GCP_PROJECT_ID, GCP_DMS_LOCATION, DMS_LOG_LOOKBACK
# Output: fetch_dms_error_logs_issues.json (usually empty; issues if critical errors found)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUTPUT_FILE="fetch_dms_error_logs_issues.json"
FLAG_FILE="dms_flagged_jobs.txt"
DMS_LOG_LOOKBACK="${DMS_LOG_LOOKBACK:-1h}"

issues_json='[]'

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

if [ ! -s "$FLAG_FILE" ]; then
  echo "No flagged DMS jobs; skipping error log correlation (healthy or not yet evaluated)."
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

# Broad DMS-related errors in project (read-only)
filter='(protoPayload.serviceName="datamigration.googleapis.com" OR resource.type="datamigration.googleapis.com/MigrationJob") AND severity>=ERROR'

if ! logs_out=$(gcloud logging read "${filter}" \
  --project="${GCP_PROJECT_ID}" \
  --freshness="${DMS_LOG_LOOKBACK}" \
  --limit=50 \
  --format=json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot query Cloud Logging for DMS errors" \
    --arg details "gcloud logging read failed: ${err_msg}" \
    --arg severity "2" \
    --arg next_steps "Grant logging.logEntries.list (roles/logging.viewer) and retry." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi
rm -f err.log

count=$(echo "$logs_out" | jq 'length' 2>/dev/null || echo "0")
if [ "${count}" -gt 0 ] 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Recent DMS-related ERROR logs found in \`${GCP_PROJECT_ID}\`" \
    --arg details "Count=${count} (lookback ${DMS_LOG_LOOKBACK}). Sample entries: $(echo "$logs_out" | jq -c '.[0:3]')" \
    --arg severity "2" \
    --arg next_steps "Triage entries below; correlate with flagged migration jobs and operations." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" >"$OUTPUT_FILE"

echo "=== DMS-related error logs (freshness ${DMS_LOG_LOOKBACK}, limit 50) ==="
gcloud logging read "${filter}" \
  --project="${GCP_PROJECT_ID}" \
  --freshness="${DMS_LOG_LOOKBACK}" \
  --limit=20 \
  --format="table[box](timestamp,severity,logName)" || true

echo "Wrote ${OUTPUT_FILE}"
