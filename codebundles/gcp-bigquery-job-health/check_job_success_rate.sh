#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"
: "${SUCCESS_RATE_THRESHOLD:=95}"

OUTPUT_FILE="job_success_rate_output.json"
issues_json='[]'

echo "Checking BigQuery job success rate for project: $GCP_PROJECT_ID"

if ! query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     COUNT(*) as total_jobs,
     COUNTIF(error_result IS NULL) as successful_jobs,
     COUNTIF(error_result IS NOT NULL) as failed_jobs,
     ROUND(SAFE_DIVIDE(COUNTIF(error_result IS NULL), COUNT(*)) * 100, 2) as success_rate
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND job_type = 'QUERY'" 2>/dev/null); then
    err_msg="bq query failed — check authentication and permissions (bigquery.jobs.listAll required)"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "BigQuery Job Success Rate Check Failed for \`$GCP_PROJECT_ID\`" \
      --arg details "Query failed: $err_msg" \
      --arg severity "3" \
      --arg expected "INFORMATION_SCHEMA.JOBS_BY_PROJECT query should execute successfully." \
      --arg actual "Query failed with error: $err_msg" \
      --arg next_steps "Verify BigQuery permissions (roles/bigquery.jobUser, roles/bigquery.metadataViewer) and ensure INFORMATION_SCHEMA is accessible." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "expected": $expected,
         "actual": $actual,
         "next_steps": $next_steps
       }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

total_jobs=$(echo "$query_result" | jq -r '.[0].total_jobs // 0')
success_rate=$(echo "$query_result" | jq -r '.[0].success_rate // 100')
failed_jobs=$(echo "$query_result" | jq -r '.[0].failed_jobs // 0')

echo "Project: $GCP_PROJECT_ID"
echo "Total jobs: $total_jobs"
echo "Success rate: $success_rate%"
echo "Failed jobs: $failed_jobs"

if [ "$failed_jobs" -gt 0 ]; then
    echo ""
    echo "--- Recent Failed Jobs (last $JOB_LOOKBACK_HOURS hours) ---"
    failed_detail=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
      "SELECT
         job_id,
         user_email,
         error_result.reason as error_reason,
         error_result.message as error_message,
         creation_time,
         SUBSTR(query, 1, 120) as query_snippet
       FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
       WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
         AND error_result IS NOT NULL
         AND job_type = 'QUERY'
       ORDER BY creation_time DESC
       LIMIT 20" 2>/dev/null || echo "[]")
    echo "$failed_detail" | jq -r '.[] | "  \(.creation_time)  [\(.error_reason)]  \(.user_email)  \(.job_id)\n    \(.query_snippet // "n/a")"' 2>/dev/null || echo "  (could not retrieve failed job details)"
fi

threshold=$SUCCESS_RATE_THRESHOLD
if (( $(echo "$success_rate < $threshold" | bc -l) )); then
    echo "ISSUE: Success rate $success_rate% is below threshold $threshold%"
    if (( total_jobs > 0 )); then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "Low BigQuery Job Success Rate in \`$GCP_PROJECT_ID\`" \
          --arg details "Job success rate is $success_rate% across $total_jobs jobs in the last $JOB_LOOKBACK_HOURS hours. Threshold is $threshold%. Failed jobs: $failed_jobs." \
          --arg severity "3" \
          --arg expected "Job success rate should be at least $threshold%" \
          --arg actual "Current success rate is $success_rate%" \
          --arg next_steps "1. Run the failed job analysis task for details on error patterns. 2. Check BigQuery quota and reservation status. 3. Review recent query changes or deployments that may have introduced errors." \
          '. += [{
             "title": $title,
             "details": $details,
             "severity": ($severity | tonumber),
             "expected": $expected,
             "actual": $actual,
             "next_steps": $next_steps
           }]')
    fi
else
    echo "HEALTHY: Success rate $success_rate% is at or above threshold $threshold%"
fi

echo ""
echo "=== LLM Context ==="
echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=$GCP_PROJECT_ID"
echo "Jobs Dashboard: https://console.cloud.google.com/bigquery/jobs?project=$GCP_PROJECT_ID"
echo "Lookback Window: $JOB_LOOKBACK_HOURS hours"
echo "Threshold: $threshold%"
echo ""
echo "Suggested Follow-up Queries:"
echo "  # List recent failed jobs with error details"
echo "  SELECT job_id, user_email, error_result.reason, error_result.message, query"
echo "  FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`"
echo "  WHERE error_result IS NOT NULL"
echo "  ORDER BY creation_time DESC LIMIT 50;"
echo ""
echo "  # Count errors by reason"
echo "  SELECT error_result.reason, COUNT(*) as count"
echo "  FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`"
echo "  WHERE error_result IS NOT NULL"
echo "  GROUP BY error_result.reason ORDER BY count DESC;"

echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"