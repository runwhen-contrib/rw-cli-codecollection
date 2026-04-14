#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists DMS migration jobs, evaluates unhealthy / stuck states, writes issues JSON.
# Env: GCP_PROJECT_ID, GCP_DMS_LOCATION, DMS_JOB_NAMES, DMS_STUCK_MINUTES
# Outputs: list_migration_jobs_issues.json, migration_jobs_list.json, dms_flagged_jobs.txt
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUTPUT_FILE="list_migration_jobs_issues.json"
JOBS_FILE="migration_jobs_list.json"
FLAG_FILE="dms_flagged_jobs.txt"

DMS_JOB_NAMES="${DMS_JOB_NAMES:-All}"
DMS_STUCK_MINUTES="${DMS_STUCK_MINUTES:-120}"

issues_json='[]'

auth_gcloud() {
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
}

short_name() {
  local full="$1"
  echo "${full##*/}"
}

iso_to_epoch() {
  local iso="$1"
  if [ -z "$iso" ] || [ "$iso" = "null" ]; then
    echo ""
    return
  fi
  date -d "$iso" +%s 2>/dev/null || date -d "${iso/Z/+0000}" +%s 2>/dev/null || echo ""
}

append_flag() {
  local id="$1"
  grep -qxF "$id" "$FLAG_FILE" 2>/dev/null || echo "$id" >>"$FLAG_FILE"
}

rm -f "$FLAG_FILE"
touch "$FLAG_FILE"

if ! auth_gcloud; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot authenticate to GCP for DMS list" \
    --arg details "gcloud auth activate-service-account failed. Verify gcp_credentials secret." \
    --arg severity "4" \
    --arg next_steps "Confirm the service account JSON is valid and has datamigration.viewer (or equivalent)." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo '[]' >"$JOBS_FILE"
  exit 0
fi

if ! jobs_raw=$(gcloud database-migration migration-jobs list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --format=json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot list DMS migration jobs in \`${GCP_PROJECT_ID}\`" \
    --arg details "gcloud database-migration migration-jobs list failed: ${err_msg}" \
    --arg severity "4" \
    --arg next_steps "Verify Database Migration API is enabled, region is correct, and IAM allows datamigration.migrationJobs.list." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo '[]' >"$JOBS_FILE"
  exit 0
fi
rm -f err.log

echo "$jobs_raw" >"$JOBS_FILE"

# Filter by DMS_JOB_NAMES when not All (comma-separated job IDs)
if [ "${DMS_JOB_NAMES}" != "All" ]; then
  jobs_filtered=$(echo "$jobs_raw" | jq -c --arg csv "${DMS_JOB_NAMES}" '
    ($csv | split(",") | map(gsub("^ +| +$";""))) as $want |
    [ .[] | select(.name != null)
      | select((.name | split("/") | .[-1]) as $id | ($want | index($id) != null)) ]
  ')
else
  jobs_filtered="$jobs_raw"
fi

now_epoch=$(date -u +%s)
stuck_sec=$((DMS_STUCK_MINUTES * 60))

while IFS= read -r job_json; do
  [ -z "$job_json" ] && continue
  state=$(echo "$job_json" | jq -r '.state // "UNKNOWN"')
  phase=$(echo "$job_json" | jq -r '.phase // empty')
  full_name=$(echo "$job_json" | jq -r '.name // ""')
  jid=$(short_name "$full_name")
  ut=$(echo "$job_json" | jq -r '.updateTime // .createTime // empty')
  ue=$(iso_to_epoch "$ut")

  case "$state" in
  FAILED)
    append_flag "$jid"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DMS migration job \`${jid}\` is FAILED" \
      --arg details "$(echo "$job_json" | jq -c .)" \
      --arg severity "4" \
      --arg next_steps "Run describe on the job, review Cloud Logging for datamigration.googleapis.com, and follow DMS troubleshooting for your engine." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    ;;
  PAUSED)
    append_flag "$jid"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DMS migration job \`${jid}\` is PAUSED" \
      --arg details "$(echo "$job_json" | jq -c .)" \
      --arg severity "2" \
      --arg next_steps "Confirm whether pause is intentional; if not, resume or investigate blocking errors in the job details." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    ;;
  CANCELLED)
    append_flag "$jid"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DMS migration job \`${jid}\` is CANCELLED" \
      --arg details "$(echo "$job_json" | jq -c .)" \
      --arg severity "3" \
      --arg next_steps "If cancellation was unexpected, create a new migration job or restore from backup per your runbook." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    ;;
  esac

  # Stuck in transitional states
  if [[ "$state" =~ ^(CREATING|UPDATING|DELETING|STARTING|RESTARTING|VERIFYING)$ ]]; then
    if [ -n "$ue" ] && [ $((now_epoch - ue)) -gt "$stuck_sec" ]; then
      append_flag "$jid"
      issues_json=$(echo "$issues_json" | jq \
        --arg title "DMS migration job \`${jid}\` may be stuck in ${state}" \
        --arg details "State=${state}, last update ${ut}, threshold ${DMS_STUCK_MINUTES}m. Raw: $(echo "$job_json" | jq -c .)" \
        --arg severity "3" \
        --arg next_steps "Inspect operations for this job, check VPC connectivity and IAM, and open a support case if the state does not progress." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi

  # Continuous replication expectation: RUNNING should eventually reach CDC for homogeneous PG/MySQL continuous jobs
  if [ "$state" = "RUNNING" ] && [ -n "$phase" ] && [ "$phase" != "CDC" ] && [ "$phase" != "PHASE_UNSPECIFIED" ]; then
    if [ -n "$ue" ] && [ $((now_epoch - ue)) -gt "$stuck_sec" ]; then
      append_flag "$jid"
      issues_json=$(echo "$issues_json" | jq \
        --arg title "DMS migration job \`${jid}\` RUNNING but not in CDC phase (${phase})" \
        --arg details "Job remains in phase ${phase} beyond ${DMS_STUCK_MINUTES}m since last update. $(echo "$job_json" | jq -c .)" \
        --arg severity "2" \
        --arg next_steps "If you require CDC / cutover readiness, wait for CDC or investigate errors in job details and logs." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
done < <(echo "$jobs_filtered" | jq -c '.[]')

echo "$issues_json" >"$OUTPUT_FILE"

echo "=== DMS migration jobs (${GCP_DMS_LOCATION}) ==="
gcloud database-migration migration-jobs list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --format="table[box](name,state,phase,updateTime)" || true

echo "Wrote ${OUTPUT_FILE}, ${JOBS_FILE}, ${FLAG_FILE}"
