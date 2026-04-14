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

gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" >/dev/null 2>&1

job_score=1
ops_score=1
lag_score=1

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
  op_err=$(echo "$ops_raw" | jq '[.[] | select(.error != null and (.error | type) == "object" and (.error | length) > 0)] | length')
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
  if ! sec_series=$(gcloud monitoring time-series list \
    --project="${GCP_PROJECT_ID}" \
    --filter="metric.type=\"datamigration.googleapis.com/migration_job/max_replica_sec_lag\" AND resource.labels.location=\"${GCP_DMS_LOCATION}\"" \
    --interval-start-time="${START}" \
    --interval-end-time="${END}" \
    --format=json 2>/dev/null); then
    lag_score=1
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
    done < <(echo "$sec_series" | jq -c '.[]')
    lag_score=$((1 - over))
  fi
fi

jq -n --argjson js "$job_score" --argjson os "$ops_score" --argjson ls "$lag_score" \
  '{job_score: $js, ops_score: $os, lag_score: $ls}' >"$OUT"
