#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Describes selected migration jobs for diagnostics. Targets come from DMS_JOB_NAMES
# or dms_flagged_jobs.txt (when DMS_JOB_NAMES is All).
# Output: describe_migration_jobs_issues.json, human summary on stdout
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUTPUT_FILE="describe_migration_jobs_issues.json"
FLAG_FILE="dms_flagged_jobs.txt"
DMS_JOB_NAMES="${DMS_JOB_NAMES:-All}"

issues_json='[]'

# Auth is established at import time by the platform (gcp:adc@cli / gcp:sa@cli).
# There the secret value is a status string, not a key file, so this call is
# expected to fail and MUST NOT be fatal - `|| true` lets execution fall through
# to the already-authenticated session (or ambient ADC in dev mode).
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" >/dev/null 2>&1 || true

declare -a TARGETS=()

if [ "${DMS_JOB_NAMES}" != "All" ]; then
  IFS=',' read -ra parts <<<"${DMS_JOB_NAMES}"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] && TARGETS+=("$p")
  done
else
  if [ -f "$FLAG_FILE" ]; then
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -z "$line" ] && continue
      TARGETS+=("$line")
    done < <(sort -u "$FLAG_FILE")
  fi
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  # With DMS_JOB_NAMES=All this task describes the jobs EARLIER TASKS FLAGGED,
  # not every job in the region - so "nothing to describe" is the healthy result.
  # Telling the operator to "set DMS_JOB_NAMES" is wrong advice when it is
  # already set to All.
  if [ "${DMS_JOB_NAMES}" = "All" ]; then
    echo "No migration jobs were flagged by the earlier health tasks, so there is nothing to describe."
    echo "This is the expected result when every migration job in ${GCP_DMS_LOCATION} is healthy."
    echo "To describe specific jobs regardless of health, set DMS_JOB_NAMES to a comma-separated list of job IDs."
  else
    echo "None of the requested migration jobs (DMS_JOB_NAMES=${DMS_JOB_NAMES}) could be resolved to describe."
  fi
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

summary="=== DMS migration job describe (${GCP_DMS_LOCATION}) ==="$'\n'

for jid in "${TARGETS[@]}"; do
  if ! desc=$(gcloud database-migration migration-jobs describe "${jid}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_DMS_LOCATION}" \
    --format=json 2>err.log); then
    err_msg=$(cat err.log || true)
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot describe DMS migration job \`${jid}\`" \
      --arg details "describe failed: ${err_msg}" \
      --arg severity "3" \
      --arg next_steps "Verify job ID, region, and IAM datamigration.migrationJobs.get." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    continue
  fi
  rm -f err.log

  summary+=$'---\n'"${jid}"$'\n'
  summary+=$(echo "$desc" | jq -r '"state: \(.state // "n/a") phase: \(.phase // "n/a")"' 2>/dev/null || echo "$desc")$'\n'

  err_block=$(echo "$desc" | jq -c '.error // empty' 2>/dev/null || echo "{}")
  if [ "$err_block" != "{}" ] && [ -n "$err_block" ] && [ "$err_block" != "null" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DMS migration job \`${jid}\` describe shows an error block" \
      --arg details "$(echo "$desc" | jq -c .)" \
      --arg severity "4" \
      --arg next_steps "Resolve the reported error: check connectivity, credentials, and engine-specific prerequisites." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
done

echo "$issues_json" >"$OUTPUT_FILE"
echo "${summary}"
