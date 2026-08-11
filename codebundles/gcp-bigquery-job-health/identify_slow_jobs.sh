#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"
: "${SLOW_JOB_DURATION_MINUTES:=30}"

OUTPUT_FILE="slow_jobs_output.json"
issues_json='[]'

echo "Identifying slow BigQuery jobs for project: $GCP_PROJECT_ID"

if ! query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     job_id,
     user_email,
     query,
     TIMESTAMP_DIFF(end_time, start_time, SECOND) as duration_seconds,
     total_bytes_processed,
     total_slot_ms,
     state,
     error_result.reason as error_reason,
     creation_time,
     start_time,
     end_time
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND TIMESTAMP_DIFF(end_time, start_time, SECOND) > ($SLOW_JOB_DURATION_MINUTES * 60)
     AND job_type = 'QUERY'
   ORDER BY duration_seconds DESC
   LIMIT 50" 2>&1); then
    err_msg="${query_result:-no output}"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Slow Jobs Query Failed for \`$GCP_PROJECT_ID\`" \
      --arg details "Query failed: $err_msg" \
      --arg severity "3" \
      --arg expected "INFORMATION_SCHEMA.JOBS_BY_PROJECT query for slow jobs should execute successfully." \
      --arg actual "Query failed with error: $err_msg" \
      --arg next_steps "Verify BigQuery permissions and INFORMATION_SCHEMA access." \
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

slow_job_count=$(echo "$query_result" | jq -r 'length')

echo "Found $slow_job_count slow jobs (exceeding ${SLOW_JOB_DURATION_MINUTES} minutes)"

if [ "$slow_job_count" -eq 0 ]; then
    echo "No slow jobs detected. All jobs completed within the configured threshold."
fi

if [ "$slow_job_count" -gt 0 ]; then
    slow_threshold=$SLOW_JOB_DURATION_MINUTES

    if [ "$slow_job_count" -gt 20 ]; then
        severity=4
        expected="Fewer than 10% of BigQuery jobs should exceed the ${slow_threshold} minute duration threshold."
        actual="$slow_job_count jobs exceeded ${slow_threshold} minutes, indicating widespread performance issues."
        next_steps="1. Check for systemic performance issues like slot contention. 2. Review slot reservation and capacity. 3. Consider tuning query performance with clustering and partitioning. 4. Investigate if a recent deployment or data change caused the slowdown."
    elif [ "$slow_job_count" -gt 5 ]; then
        severity=3
        expected="BigQuery jobs should complete within the configured duration threshold of ${slow_threshold} minutes."
        actual="$slow_job_count jobs exceeded ${slow_threshold} minutes, indicating moderate performance concerns."
        next_steps="1. Review the identified slow jobs for optimization opportunities. 2. Check slot utilization during the affected period. 3. Consider materialized views or query rewriting for repeated slow queries."
    else
        severity=2
        expected="All BigQuery jobs should complete within the configured duration threshold of ${slow_threshold} minutes."
        actual="$slow_job_count jobs exceeded ${slow_threshold} minutes."
        next_steps="1. Review each slow job individually for optimization. 2. Check if these are expected batch jobs. 3. Consider if the threshold needs adjustment."
    fi

    title="BigQuery Slow Jobs Detected in \`$GCP_PROJECT_ID\` ($slow_job_count jobs over ${slow_threshold}min)"

    echo ""
    echo "--- Slow Job Details ---"
    printf "%-50s %-30s %10s %15s\n" "JOB_ID" "USER" "DURATION" "BYTES_PROCESSED"

    details="Found $slow_job_count jobs exceeding ${slow_threshold} minutes in the last $JOB_LOOKBACK_HOURS hours."
    details+=" Slow job details:"
    while IFS= read -r job; do
        job_id=$(echo "$job" | jq -r '.job_id // "unknown"')
        user=$(echo "$job" | jq -r '.user_email // "unknown"')
        dur=$(echo "$job" | jq -r '.duration_seconds // 0')
        proc=$(echo "$job" | jq -r '.total_bytes_processed // 0')
        printf "%-50s %-30s %10s %15s\n" "$job_id" "$user" "${dur}s" "$proc"
        details+="\n- Job: $job_id | User: $user | Duration: ${dur}s | Bytes: $proc"
    done < <(echo "$query_result" | jq -c '.[]')

    issues_json=$(echo "$issues_json" | jq \
      --arg title "$title" \
      --arg details "$details" \
      --arg severity "$severity" \
      --arg expected "$expected" \
      --arg actual "$actual" \
      --arg next_steps "$next_steps" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "expected": $expected,
         "actual": $actual,
         "next_steps": $next_steps
       }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"