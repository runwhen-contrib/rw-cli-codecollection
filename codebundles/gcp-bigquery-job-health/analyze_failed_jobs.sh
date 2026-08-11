#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"

OUTPUT_FILE="failed_jobs_analysis_output.json"
issues_json='[]'

echo "Analyzing failed BigQuery job error patterns for project: $GCP_PROJECT_ID"

if ! query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     error_result.reason as error_reason,
     COUNT(*) as error_count
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND error_result IS NOT NULL
     AND job_type = 'QUERY'
   GROUP BY error_reason
   ORDER BY error_count DESC" 2>&1); then
    err_msg="${query_result:-no output}"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Failed Jobs Analysis Query Failed for \`$GCP_PROJECT_ID\`" \
      --arg details "Query failed: $err_msg" \
      --arg severity "3" \
      --arg expected "INFORMATION_SCHEMA.JOBS_BY_PROJECT error analysis query should execute successfully." \
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

error_categories=$(echo "$query_result" | jq -c '.[]')

severity_map() {
    local reason="$1"
    case "$reason" in
        quotaExceeded|quota_exceeded) echo "3" ;;
        accessDenied|access_denied) echo "3" ;;
        invalidQuery|invalid_query) echo "2" ;;
        timeout|timedOut) echo "3" ;;
        rateLimitExceeded|rate_limit_exceeded) echo "2" ;;
        datasetNotFound|tableNotFound|notFound) echo "2" ;;
        resourcesExceeded|resources_exceeded) echo "3" ;;
        *) echo "2" ;;
    esac
}

severity_map_expected() {
    local reason="$1"
    case "$reason" in
        quotaExceeded|quota_exceeded) echo "BigQuery quotas and limits should not be exceeded." ;;
        accessDenied|access_denied) echo "All queries should have proper access permissions." ;;
        invalidQuery|invalid_query) echo "Queries should be syntactically valid." ;;
        timeout|timedOut) echo "Queries should complete within the configured timeout." ;;
        rateLimitExceeded|rate_limit_exceeded) echo "API rate limits should not be exceeded." ;;
        datasetNotFound|tableNotFound|notFound) echo "All referenced datasets and tables should exist." ;;
        resourcesExceeded|resources_exceeded) echo "Query resources (memory/shuffle) should be sufficient." ;;
        *) echo "Jobs should complete without errors." ;;
    esac
}

severity_map_actual() {
    local reason="$1"
    case "$reason" in
        quotaExceeded|quota_exceeded) echo "Quota limit has been exceeded for one or more BigQuery resources." ;;
        accessDenied|access_denied) echo "Access denied errors detected, possibly due to missing permissions." ;;
        invalidQuery|invalid_query) echo "Invalid queries detected, possibly due to schema changes or syntax errors." ;;
        timeout|timedOut) echo "Queries are timing out, possibly due to complexity or resource contention." ;;
        rateLimitExceeded|rate_limit_exceeded) echo "API rate limit has been exceeded." ;;
        datasetNotFound|tableNotFound|notFound) echo "Referenced datasets or tables are missing." ;;
        resourcesExceeded|resources_exceeded) echo "Query exceeded available resources." ;;
        *) echo "Unexpected error patterns detected." ;;
    esac
}

severity_map_next_steps() {
    local reason="$1"
    case "$reason" in
        quotaExceeded|quota_exceeded) echo "1. Request quota increase in GCP Console. 2. Optimize query patterns to reduce consumption. 3. Consider slot reservations for predictable workloads." ;;
        accessDenied|access_denied) echo "1. Review IAM permissions for the service account. 2. Check dataset-level ACLs. 3. Verify authorized views and routines." ;;
        invalidQuery|invalid_query) echo "1. Review query syntax in the failing jobs. 2. Check for schema changes that may break existing queries. 3. Test queries in BigQuery console." ;;
        timeout|timedOut) echo "1. Optimize query performance with clustering/partitioning. 2. Increase query timeout if appropriate. 3. Reduce query complexity or use materialized views." ;;
        rateLimitExceeded|rate_limit_exceeded) echo "1. Implement exponential backoff in applications. 2. Reduce concurrent query volume. 3. Distribute queries across time." ;;
        datasetNotFound|tableNotFound|notFound) echo "1. Verify dataset and table names. 2. Check if tables have been deleted or renamed. 3. Update references in queries and views." ;;
        resourcesExceeded|resources_exceeded) echo "1. Optimize JOINs and GROUP BY operations. 2. Increase slot capacity. 3. Use approximate aggregation functions where possible." ;;
        *) echo "1. Review the failed job details in BigQuery console. 2. Check error messages for guidance." ;;
    esac
}

echo "$error_categories" | while read -r category; do
    reason=$(echo "$category" | jq -r '.error_reason')
    count=$(echo "$category" | jq -r '.error_count')
    severity=$(severity_map "$reason")
    expected=$(severity_map_expected "$reason")
    actual=$(severity_map_actual "$reason")
    next_steps=$(severity_map_next_steps "$reason")

    printf "  %-30s %s occurrences (severity %s)\n" "$reason" "$count" "$severity"

    issues_json=$(echo "$issues_json" | jq \
      --arg title "Frequent BigQuery Error: \`$reason\` in \`$GCP_PROJECT_ID\` ($count occurrences)" \
      --arg details "Error reason: $reason occurred $count times in the last $JOB_LOOKBACK_HOURS hours." \
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
    echo "$issues_json" > "$OUTPUT_FILE"
done

echo ""
echo "--- Sample Failed Jobs (newest 15) ---"
sample_jobs=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     job_id,
     user_email,
     error_result.reason as error_reason,
     SUBSTR(error_result.message, 1, 200) as error_message,
     creation_time,
     SUBSTR(query, 1, 100) as query_snippet
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`
   WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
     AND error_result IS NOT NULL
     AND job_type = 'QUERY'
   ORDER BY creation_time DESC
   LIMIT 15" 2>&1 || echo "[]")
echo "$sample_jobs" | jq -r '.[] | "  \(.creation_time)  [\(.error_reason)]  \(.user_email)\n    Job: \(.job_id)\n    Query: \(.query_snippet // "n/a")\n    Message: \(.error_message // "n/a")"' 2>/dev/null || echo "  (could not retrieve sample failed jobs)"

echo ""
echo "Analysis completed. Results saved to $OUTPUT_FILE"