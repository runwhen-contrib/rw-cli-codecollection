#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"

OUTPUT_FILE="job_summary_output.json"

echo "Generating BigQuery job health summary for project: $GCP_PROJECT_ID"

summary_data='{}'

if query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     COUNT(*) as total_jobs,
     COUNTIF(error_result IS NULL) as successful_jobs,
     COUNTIF(error_result IS NOT NULL) as failed_jobs,
     ROUND(SAFE_DIVIDE(COUNTIF(error_result IS NULL), COUNT(*)) * 100, 2) as success_rate,
     ROUND(AVG(TIMESTAMP_DIFF(end_time, start_time, SECOND)), 2) as avg_duration_seconds,
     ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(end_time, start_time, SECOND), 100)[OFFSET(95)], 2) as p95_duration_seconds,
     ROUND(SUM(total_bytes_processed) / POWER(1024, 4), 2) as total_data_processed_tb,
     ROUND(SUM(total_slot_ms) / 1000 / 60 / 60, 2) as total_slot_hours,
     COUNT(DISTINCT user_email) as unique_users
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND job_type = 'QUERY'" 2>err.log); then
    rm -f err.log
    summary_data=$(echo "$query_result" | jq '.[0]')
fi

if error_query=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     error_result.reason as error_reason,
     COUNT(*) as count
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND error_result IS NOT NULL
     AND job_type = 'QUERY'
   GROUP BY error_reason
   ORDER BY count DESC" 2>/dev/null); then
    error_breakdown=$(echo "$error_query" | jq -c '.')
else
    error_breakdown='[]'
fi

if slot_query=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     ROUND(AVG(slot_usage) / NULLIF(AVG(slot_capacity), 0) * 100, 2) as avg_slot_utilization_pct,
     SUM(jobs_queued) as total_queued_jobs
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_TIMELINE\`
   WHERE period_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)" 2>/dev/null); then
    slot_info=$(echo "$slot_query" | jq '.[0]')
else
    slot_info='{"avg_slot_utilization_pct": null, "total_queued_jobs": null}'
fi

summary_data=$(echo "$summary_data" | jq \
  --argjson error_breakdown "$error_breakdown" \
  --argjson slot_info "$slot_info" \
  --arg project_id "$GCP_PROJECT_ID" \
  --arg lookback "$JOB_LOOKBACK_HOURS" \
  '{
     project_id: $project_id,
     lookback_hours: ($lookback | tonumber),
     total_jobs: (.total_jobs // 0),
     successful_jobs: (.successful_jobs // 0),
     failed_jobs: (.failed_jobs // 0),
     success_rate: (.success_rate // 100),
     avg_duration_seconds: (.avg_duration_seconds // 0),
     p95_duration_seconds: (.p95_duration_seconds // 0),
     total_data_processed_tb: (.total_data_processed_tb // 0),
     total_slot_hours: (.total_slot_hours // 0),
     unique_users: (.unique_users // 0),
     error_breakdown: $error_breakdown,
     slot_utilization: $slot_info
   }')

echo "$summary_data" > "$OUTPUT_FILE"
echo "Summary report generated:"
echo "$summary_data" | jq '.'
echo "Report saved to $OUTPUT_FILE"