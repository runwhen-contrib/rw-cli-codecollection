#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads migration_job/max_replica_sec_lag and optionally max_replica_bytes_lag from Monitoring.
# Only evaluates jobs in CDC phase when present in migration_jobs_list.json.
# Env: GCP_PROJECT_ID, GCP_DMS_LOCATION, REPLICATION_LAG_SEC_THRESHOLD, REPLICATION_LAG_BYTES_THRESHOLD
# Output: fetch_dms_replication_lag_issues.json, appends lag-hot jobs to dms_flagged_jobs.txt
# Note: Cloud Monitoring samples may lag observation by up to ~180s per Google documentation.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUTPUT_FILE="fetch_dms_replication_lag_issues.json"
JOBS_FILE="migration_jobs_list.json"
FLAG_FILE="dms_flagged_jobs.txt"

REPLICATION_LAG_SEC_THRESHOLD="${REPLICATION_LAG_SEC_THRESHOLD:-300}"
REPLICATION_LAG_BYTES_THRESHOLD="${REPLICATION_LAG_BYTES_THRESHOLD:-0}"

issues_json='[]'
touch "$FLAG_FILE"

append_flag() {
  local id="$1"
  grep -qxF "$id" "$FLAG_FILE" 2>/dev/null || echo "$id" >>"$FLAG_FILE"
}

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

if [ ! -f "$JOBS_FILE" ]; then
  echo "[]" >"$JOBS_FILE"
fi

# Job IDs in CDC only (lag metrics meaningful; exclude dump / non-CDC phases)
cdc_jobs=$(jq -r '
  [.[]? | select(.state == "RUNNING") | select((.phase // "") == "CDC")]
  | map(.name | split("/") | .[-1])
  | unique | .[]
' "$JOBS_FILE" 2>/dev/null || true)

if [ -z "$(echo "$cdc_jobs" | tr -d '[:space:]')" ]; then
  echo "No RUNNING jobs in CDC phase; skipping replication lag checks (normal during full dump / non-CDC work)."
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)

if ! sec_series=$(gcloud monitoring time-series list \
  --project="${GCP_PROJECT_ID}" \
  --filter="metric.type=\"datamigration.googleapis.com/migration_job/max_replica_sec_lag\" AND resource.labels.location=\"${GCP_DMS_LOCATION}\"" \
  --interval-start-time="${START}" \
  --interval-end-time="${END}" \
  --format=json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot read DMS replication lag (seconds) from Cloud Monitoring" \
    --arg details "gcloud monitoring time-series list failed: ${err_msg}" \
    --arg severity "3" \
    --arg next_steps "Grant monitoring.timeSeries.list (roles/monitoring.viewer) and confirm metric types for your engine." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi
rm -f err.log

# Parse latest point per migration_job_id label
while IFS= read -r row; do
  [ -z "$row" ] && continue
  jid=$(echo "$row" | jq -r '.resource.labels.migration_job_id // empty')
  [ -z "$jid" ] && continue
  # Only evaluate jobs we care about (subset of project jobs)
  if ! echo "$cdc_jobs" | grep -qxF "$jid" 2>/dev/null; then
    continue
  fi
  val=$(echo "$row" | jq -r '
    [ .points[]? | .value.doubleValue // .value.int64Value // empty ] | last // empty
  ')
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    continue
  fi
  # Compare — use awk for float
  if awk -v v="$val" -v t="$REPLICATION_LAG_SEC_THRESHOLD" 'BEGIN{exit !(v>t)}'; then
    append_flag "$jid"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "High DMS replication lag (seconds) for job \`${jid}\`" \
      --arg details "max_replica_sec_lag=${val}s (threshold ${REPLICATION_LAG_SEC_THRESHOLD}s). Monitoring samples may trail real time by up to ~180s." \
      --arg severity "3" \
      --arg next_steps "Before cutover, reduce lag; check source load, network, and DMS CDC health. See migration job metrics documentation." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
done < <(echo "$sec_series" | jq -c '.[]')

if [ "${REPLICATION_LAG_BYTES_THRESHOLD}" != "0" ] && [ -n "${REPLICATION_LAG_BYTES_THRESHOLD}" ]; then
  if byte_series=$(gcloud monitoring time-series list \
    --project="${GCP_PROJECT_ID}" \
    --filter="metric.type=\"datamigration.googleapis.com/migration_job/max_replica_bytes_lag\" AND resource.labels.location=\"${GCP_DMS_LOCATION}\"" \
    --interval-start-time="${START}" \
    --interval-end-time="${END}" \
    --format=json 2>/dev/null); then
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      jid=$(echo "$row" | jq -r '.resource.labels.migration_job_id // empty')
      [ -z "$jid" ] && continue
      if ! echo "$cdc_jobs" | grep -qxF "$jid" 2>/dev/null; then
        continue
      fi
      val=$(echo "$row" | jq -r '[ .points[]? | .value.doubleValue // .value.int64Value // empty ] | last // empty')
      if [ -z "$val" ]; then
        continue
      fi
      if awk -v v="$val" -v t="$REPLICATION_LAG_BYTES_THRESHOLD" 'BEGIN{exit !(v>t)}'; then
        append_flag "$jid"
        issues_json=$(echo "$issues_json" | jq \
          --arg title "High DMS replication lag (bytes) for job \`${jid}\`" \
          --arg details "max_replica_bytes_lag=${val} (threshold ${REPLICATION_LAG_BYTES_THRESHOLD})." \
          --arg severity "2" \
          --arg next_steps "Investigate backlog size and destination apply rate before promotion." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
      fi
    done < <(echo "$byte_series" | jq -c '.[]')
  fi
fi

echo "$issues_json" >"$OUTPUT_FILE"
echo "=== Replication lag check complete (sec threshold=${REPLICATION_LAG_SEC_THRESHOLD}) ==="
echo "Wrote ${OUTPUT_FILE}"
