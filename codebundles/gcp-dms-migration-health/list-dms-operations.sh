#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists recent DMS operations; flags failures, cancellations, and long-running ops.
# Env: GCP_PROJECT_ID, GCP_DMS_LOCATION, DMS_OPERATION_STUCK_MINUTES, DMS_OPERATION_LIMIT
# Appends related job IDs to dms_flagged_jobs.txt
# Output: list_dms_operations_issues.json
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUTPUT_FILE="list_dms_operations_issues.json"
FLAG_FILE="dms_flagged_jobs.txt"
DMS_OPERATION_STUCK_MINUTES="${DMS_OPERATION_STUCK_MINUTES:-45}"
DMS_OPERATION_LIMIT="${DMS_OPERATION_LIMIT:-50}"

issues_json='[]'
touch "$FLAG_FILE"

append_flag() {
  local id="$1"
  [ -z "$id" ] || [ "$id" = "null" ] && return
  grep -qxF "$id" "$FLAG_FILE" 2>/dev/null || echo "$id" >>"$FLAG_FILE"
}

extract_job_from_metadata() {
  echo "$1" | jq -c . 2>/dev/null | grep -oE 'migrationJobs/[a-zA-Z0-9][a-zA-Z0-9_-]*' | head -1 | cut -d/ -f2 || true
}

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

if ! ops_raw=$(gcloud database-migration operations list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --limit="${DMS_OPERATION_LIMIT}" \
  --format=json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot list DMS operations in \`${GCP_PROJECT_ID}\` (${GCP_DMS_LOCATION})" \
    --arg details "gcloud database-migration operations list failed: ${err_msg}" \
    --arg severity "3" \
    --arg next_steps "Verify datamigration.operations.list permission and region." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi
rm -f err.log

now_epoch=$(date -u +%s)
stuck_sec=$((DMS_OPERATION_STUCK_MINUTES * 60))

while IFS= read -r op; do
  [ -z "$op" ] && continue
  done_flag=$(echo "$op" | jq -r '.done // false')
  err=$(echo "$op" | jq -c '.error // empty')
  name=$(echo "$op" | jq -r '.name // ""')
  jid=$(extract_job_from_metadata "$op")

  if [ "$err" != "{}" ] && [ -n "$err" ]; then
    append_flag "$jid"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DMS operation reported an error (${name##*/})" \
      --arg details "$(echo "$op" | jq -c .)" \
      --arg severity "3" \
      --arg next_steps "Correlate with migration job ${jid:-unknown}: review job describe output and Cloud Logging for datamigration.googleapis.com." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi

  if [ "$done_flag" = "false" ]; then
    st=$(echo "$op" | jq -r '.metadata.startTime // .metadata["@type"] // empty' 2>/dev/null || echo "")
    # Some operations expose start via metadata
    st=$(echo "$op" | jq -r '.. | .startTime? // empty' | head -1)
    se=""
    if [ -n "$st" ] && [ "$st" != "null" ]; then
      se=$(date -d "$st" +%s 2>/dev/null || echo "")
    fi
    if [ -n "$se" ] && [ $((now_epoch - se)) -gt "$stuck_sec" ]; then
      append_flag "$jid"
      issues_json=$(echo "$issues_json" | jq \
        --arg title "DMS operation may be stuck (not done): ${name##*/}" \
        --arg details "Running longer than ${DMS_OPERATION_STUCK_MINUTES}m. $(echo "$op" | jq -c .)" \
        --arg severity "2" \
        --arg next_steps "Check migration job progress, quotas, and network paths; cancel/retry per Google DMS guidance if appropriate." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
done < <(echo "$ops_raw" | jq -c '.[]')

echo "$issues_json" >"$OUTPUT_FILE"

echo "=== Recent DMS operations (${GCP_DMS_LOCATION}, limit ${DMS_OPERATION_LIMIT}) ==="
gcloud database-migration operations list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --limit="${DMS_OPERATION_LIMIT}" \
  --format="table[box](name,done)" || true

echo "Wrote ${OUTPUT_FILE}"
