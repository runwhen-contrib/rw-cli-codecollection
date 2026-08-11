#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${JOB_LOOKBACK_HOURS:=24}"
: "${SLOT_CONTENTION_THRESHOLD:=1000000}"

OUTPUT_FILE="slot_contention_output.json"
issues_json='[]'

echo "Checking BigQuery slot contention for project: $GCP_PROJECT_ID"

if ! query_result=$(bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
  "SELECT
     TIMESTAMP_TRUNC(period_start, HOUR) as hour,
     SUM(period_slot_ms) as total_slot_ms,
     COUNT(*) as timeline_entries
   FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_TIMELINE\`
   WHERE period_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $JOB_LOOKBACK_HOURS HOUR)
   GROUP BY hour
   ORDER BY hour DESC
   LIMIT 48" 2>/dev/null); then
    err_msg="bq query failed — check that a BigQuery reservation exists and the account has bigquery.resourceViewer"
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
    if echo "$err_msg" | grep -q "Unrecognized name"; then
        echo ""
        echo "--- JOBS_TIMELINE Column Debug ---"
        echo "Attempting to discover available columns in JOBS_TIMELINE..."
        bq query --project_id="$GCP_PROJECT_ID" --format=json --use_legacy_sql=false \
          "SELECT column_name, data_type FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name = 'JOBS_TIMELINE' ORDER BY ordinal_position" 2>/dev/null | \
          jq -r '.[] | "  \(.column_name) (\(.data_type))"' 2>/dev/null || \
          echo "  (JOBS_TIMELINE schema not accessible — reservation may be required)"
    fi
    exit 0
fi

contention_periods=$(echo "$query_result" | jq -c "[.[] | select(.total_slot_ms > $SLOT_CONTENTION_THRESHOLD)]")
contention_count=$(echo "$contention_periods" | jq -r 'length')
peak_slot_ms=$(echo "$query_result" | jq -r '[.[].total_slot_ms] | max // 0')
avg_slot_ms=$(echo "$query_result" | jq -r '[.[].total_slot_ms] | add / length // 0')
total_time_periods=$(echo "$query_result" | jq -r 'length')

echo "Slot utilization report (last $JOB_LOOKBACK_HOURS hours, ${SLOT_CONTENTION_THRESHOLD} slot-ms threshold):"
echo "  Time periods analyzed: $total_time_periods"
echo "  Peak slot-ms: $peak_slot_ms"
echo "  Average slot-ms: $avg_slot_ms"
echo "  Contention periods (>${SLOT_CONTENTION_THRESHOLD} slot-ms): $contention_count"

if [ "$contention_count" -gt 0 ]; then
    if [ "$contention_count" -gt 10 ]; then
        severity=3
        expected="Slot consumption should remain below ${SLOT_CONTENTION_THRESHOLD} slot-ms per hour to avoid job queuing."
        actual="Slot contention detected across $contention_count time periods with peak of ${peak_slot_ms} slot-ms. Average is ${avg_slot_ms} slot-ms."
        title="Significant BigQuery Slot Contention in \`$GCP_PROJECT_ID\`"
        next_steps="1. Increase slot reservation capacity. 2. Distribute large queries across different times. 3. Use workload management to prioritize critical queries. 4. Consider purchasing flex slots for peak periods."
    else
        severity=2
        expected="Slot consumption should remain below ${SLOT_CONTENTION_THRESHOLD} slot-ms per hour."
        actual="Slot contention detected across $contention_count time periods. Peak was ${peak_slot_ms} slot-ms."
        title="BigQuery Slot Contention Detected in \`$GCP_PROJECT_ID\`"
        next_steps="1. Monitor slot utilization trends. 2. Review if slot capacity is appropriate for workload. 3. Optimize queries that consume excessive slots."
    fi

    issues_json=$(echo "$issues_json" | jq \
      --arg title "$title" \
      --arg details "Slot contention detected in $contention_count periods over the last $JOB_LOOKBACK_HOURS hours. Peak: ${peak_slot_ms} slot-ms. Avg: ${avg_slot_ms} slot-ms." \
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