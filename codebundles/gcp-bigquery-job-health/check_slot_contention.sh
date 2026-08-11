#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"
: "${SLOT_CONTENTION_THRESHOLD:=80}"

OUTPUT_FILE="slot_contention_output.json"
issues_json='[]'

echo "Checking BigQuery slot contention for project: $GCP_PROJECT_ID"

if ! query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     TIMESTAMP_TRUNC(period_start, HOUR) as hour,
     SUM(slot_usage) / SUM(slot_capacity) * 100 as slot_utilization_pct,
     SUM(jobs_queued) as total_queued_jobs,
     SUM(slot_usage) as total_slot_usage,
     SUM(slot_capacity) as total_slot_capacity
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_TIMELINE\`
   WHERE period_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
   GROUP BY hour
   ORDER BY hour DESC
   LIMIT 48" 2>&1); then
    err_msg="${query_result:-no output}"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Slot Contention Query Failed for \`$GCP_PROJECT_ID\`" \
      --arg details "Query failed. This may happen if JOBS_TIMELINE is not available or if there is no reservation. Error: $err_msg" \
      --arg severity "2" \
      --arg expected "INFORMATION_SCHEMA.JOBS_TIMELINE query should execute successfully if a reservation exists." \
      --arg actual "Query failed with error: $err_msg" \
      --arg next_steps "Slot contention analysis requires a reservation. If no reservation exists, this is informational only." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "expected": $expected,
         "actual": $actual,
         "next_steps": $next_steps
       }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo ""
    echo "Slot contention analysis could not be completed."
    echo "JOBS_TIMELINE requires a BigQuery reservation to be provisioned."
    echo "If no reservation exists, slot contention monitoring is not applicable."
    exit 0
fi

contention_periods=$(echo "$query_result" | jq -c "[.[] | select(.slot_utilization_pct > $SLOT_CONTENTION_THRESHOLD)]")
contention_count=$(echo "$contention_periods" | jq -r 'length')
peak_utilization=$(echo "$query_result" | jq -r '[.[].slot_utilization_pct] | max // 0')
avg_utilization=$(echo "$query_result" | jq -r '[.[].slot_utilization_pct] | add / length // 0')
total_time_periods=$(echo "$query_result" | jq -r 'length')

echo "Slot utilization report (last $JOB_LOOKBACK_HOURS hours, ${SLOT_CONTENTION_THRESHOLD}% threshold):"
echo "  Time periods analyzed: $total_time_periods"
echo "  Peak utilization: ${peak_utilization}%"
echo "  Average utilization: ${avg_utilization}%"
echo "  Contention periods (>${SLOT_CONTENTION_THRESHOLD}%): $contention_count"

if [ "$contention_count" -gt 0 ]; then
    total_queued=$(echo "$contention_periods" | jq -r '[.[].total_queued_jobs] | add // 0')

    if [ "$contention_count" -gt 10 ]; then
        severity=3
        expected="Slot utilization should remain below ${SLOT_CONTENTION_THRESHOLD}% to avoid job queuing and performance degradation."
        actual="Slot contention detected across $contention_count time periods with $total_queued queued jobs and peak utilization of ${peak_utilization}%. Average utilization is ${avg_utilization}%."
        title="Significant BigQuery Slot Contention in \`$GCP_PROJECT_ID\`"
        next_steps="1. Increase slot reservation capacity. 2. Distribute large queries across different times. 3. Use workload management to prioritize critical queries. 4. Consider purchasing flex slots for peak periods."
    else
        severity=2
        expected="Slot utilization should remain below ${SLOT_CONTENTION_THRESHOLD}% to maintain consistent job performance."
        actual="Slot contention detected across $contention_count time periods. Peak utilization was ${peak_utilization}%."
        title="BigQuery Slot Contention Detected in \`$GCP_PROJECT_ID\`"
        next_steps="1. Monitor slot utilization trends. 2. Review if slot capacity is appropriate for workload. 3. Optimize queries that consume excessive slots."
    fi

    issues_json=$(echo "$issues_json" | jq \
      --arg title "$title" \
      --arg details "Slot contention detected in $contention_count periods over the last $JOB_LOOKBACK_HOURS hours. Peak utilization: ${peak_utilization}%. Avg utilization: ${avg_utilization}%. Total queued jobs: $total_queued." \
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
else
    echo ""
    echo "No slot contention detected. Slot utilization is within the configured threshold."
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"