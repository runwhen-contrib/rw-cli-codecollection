#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Lightweight SLI: writes sli_dms_scores.json with binary sub-scores (0/1) for aggregation.
# Uses gcloud database-migration list + monitoring lag sample.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${GCP_DMS_LOCATION:?Must set GCP_DMS_LOCATION}"

OUT="sli_dms_scores.json"
REPLICATION_LAG_SEC_THRESHOLD="${REPLICATION_LAG_SEC_THRESHOLD:-300}"
DMS_OPERATION_LOOKBACK_MINUTES="${DMS_OPERATION_LOOKBACK_MINUTES:-60}"

# -----------------------------------------------------------------------------
# `gcloud monitoring time-series list` does not exist - reading time series
# requires the Monitoring REST API. The quota project header is required or the
# call is rejected for service-account callers.
# Prints the response body; returns non-zero only on a real transport/HTTP error
# (an empty timeSeries array is a successful "no samples" answer).
# -----------------------------------------------------------------------------
fetch_timeseries() {
  local metric="$1" token body code
  token=$(gcloud auth print-access-token 2>/dev/null) || return 1
  body=$(curl -s -G -w $'\n%{http_code}' \
    "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries" \
    -H "Authorization: Bearer ${token}" \
    -H "x-goog-user-project: ${GCP_PROJECT_ID}" \
    --data-urlencode "filter=metric.type=\"${metric}\" AND resource.labels.location=\"${GCP_DMS_LOCATION}\"" \
    --data-urlencode "interval.startTime=${START}" \
    --data-urlencode "interval.endTime=${END}") || return 1
  code=$(printf '%s' "$body" | tail -n1)
  printf '%s' "$body" | sed '$d'
  [ "$code" = "200" ]
}

# Auth is established at import time by the platform (gcp:adc@cli / gcp:sa@cli).
# There the secret value is a status string, not a key file, so this call is
# expected to fail and MUST NOT be fatal - `|| true` lets execution fall through
# to the already-authenticated session (or ambient ADC in dev mode).
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" >/dev/null 2>&1 || true

job_score=1
ops_score=1
lag_score=1
lag_error=""

if ! jobs_raw=$(gcloud database-migration migration-jobs list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --format=json 2>/dev/null); then
  jq -n '{job_score:0, ops_score:0, lag_score:0, error:"list_failed"}' >"$OUT"
  exit 0
fi

bad=$(echo "$jobs_raw" | jq '[.[] | select(.state == "FAILED" or .state == "CANCELLED")] | length')
if [ "${bad:-0}" -gt 0 ] 2>/dev/null; then
  job_score=0
fi

if ! ops_raw=$(gcloud database-migration operations list \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_DMS_LOCATION}" \
  --limit=30 \
  --format=json 2>/dev/null); then
  ops_score=0
else
  # Only consider RECENT operation failures. Without a window a single old
  # failed operation pins this dimension to 0 forever and the SLI can never
  # recover to healthy, even long after the problem is fixed.
  op_cutoff=$(date -u -d "${DMS_OPERATION_LOOKBACK_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${DMS_OPERATION_LOOKBACK_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)
  op_err=$(echo "$ops_raw" | jq --arg cutoff "$op_cutoff" '[.[]
    | select(.error != null and (.error | type) == "object" and (.error | length) > 0)
    | select((.metadata.createTime // "") >= $cutoff)] | length')
  if [ "${op_err:-0}" -gt 0 ] 2>/dev/null; then
    ops_score=0
  fi
fi

cdc=$(echo "$jobs_raw" | jq '[.[] | select(.state == "RUNNING") | select((.phase // "") == "CDC")] | length')
if [ "${cdc:-0}" -eq 0 ] 2>/dev/null; then
  lag_score=1
else
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
  if ! sec_series=$(fetch_timeseries "datamigration.googleapis.com/migration_job/max_replica_sec_lag"); then
    # Jobs ARE actively replicating (cdc > 0) but the lag metric could not be
    # read. Reporting "healthy" here would silently hide real replication lag,
    # so score the dimension unhealthy and record why.
    lag_score=0
    lag_error="monitoring_query_failed"
  elif [ "$(echo "$sec_series" | jq '[.timeSeries[]?] | length')" -eq 0 ]; then
    # Query succeeded but Monitoring has no samples yet. DMS lag samples only
    # appear a few minutes after CDC begins, and absence of data is not
    # evidence of lag - do not fail the dimension for it.
    lag_score=1
    lag_error="no_lag_samples_yet"
  else
    over=0
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      val=$(echo "$row" | jq -r '[ .points[]? | .value.doubleValue // .value.int64Value // empty ] | last // empty')
      [ -z "$val" ] || [ "$val" = "null" ] && continue
      if awk -v v="$val" -v t="$REPLICATION_LAG_SEC_THRESHOLD" 'BEGIN{exit !(v>t)}'; then
        over=1
        break
      fi
    done < <(echo "$sec_series" | jq -c '.timeSeries[]?')
    lag_score=$((1 - over))
  fi
fi

jq -n --argjson js "$job_score" --argjson os "$ops_score" --argjson ls "$lag_score" \
  --arg le "${lag_error:-}" \
  '{job_score: $js, ops_score: $os, lag_score: $ls}
   + (if $le == "" then {} else {lag_error: $le} end)' >"$OUT"
