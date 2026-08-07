#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   QUERY_LATENCY_THRESHOLD_MS  (default 100)  -- mean query latency (ms) ceiling
#   STATS_WINDOW                (default HOUR) -- MINUTE, 10MINUTE, or HOUR
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.QUERY_STATS_TOP_<STATS_WINDOW>
#      ordered by AVG_LATENCY_SECONDS DESC
#   3) Flags query shapes whose mean latency exceeds QUERY_LATENCY_THRESHOLD_MS
#   4) An EMPTY result set means the database had no traffic in the stats
#      window -- this is NOT an issue, it is skipped silently
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${QUERY_LATENCY_THRESHOLD_MS:=100}"
: "${STATS_WINDOW:=HOUR}"

case "$STATS_WINDOW" in
  MINUTE|10MINUTE|HOUR) ;;
  *)
    echo "Unrecognized STATS_WINDOW '$STATS_WINDOW'; falling back to HOUR." >&2
    STATS_WINDOW="HOUR"
    ;;
esac

OUTPUT_FILE="high_latency_queries_issues.json"
TABLE_NAME="QUERY_STATS_TOP_${STATS_WINDOW}"
PARTS_FILE="/tmp/high_latency_queries_parts.jsonl"

echo "Checking Cloud Spanner high-latency queries for project: $GCP_PROJECT_ID (window: $STATS_WINDOW, table: $TABLE_NAME)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$PARTS_FILE"

SQL="SELECT TEXT, TEXT_TRUNCATED, EXECUTION_COUNT, AVG_LATENCY_SECONDS, AVG_CPU_SECONDS, AVG_ROWS_SCANNED FROM SPANNER_SYS.${TABLE_NAME} ORDER BY AVG_LATENCY_SECONDS DESC LIMIT 20"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    if ! rows=$(gcloud spanner databases execute-sql "$db_id" \
      --instance="$instance_id" \
      --project="$GCP_PROJECT_ID" \
      --sql="$SQL" \
      --format=json 2>/tmp/hlq_err.log); then
      err_msg=$(cat /tmp/hlq_err.log 2>/dev/null || echo "unknown error")
      issue=$(jq -n \
        --arg title "Cannot query QUERY_STATS for database \`$db_id\` (instance \`$instance_id\`)" \
        --arg details "gcloud spanner databases execute-sql against SPANNER_SYS.${TABLE_NAME} failed on database \`$db_id\`/instance \`$instance_id\`: $err_msg" \
        --argjson severity 3 \
        --arg expected "SPANNER_SYS.${TABLE_NAME} should be queryable with Spanner Database Reader access" \
        --arg actual "The execute-sql call failed" \
        --arg next_steps "Verify the service account has spanner.databases.select on \`$db_id\` and that Cloud Spanner API access is not blocked." \
        --arg instance "$instance_id" \
        --arg database "$db_id" \
        '{title:$title, details:$details, severity:$severity, expected:$expected, actual:$actual, next_steps:$next_steps, instance:$instance, database:$database}')
      echo "$issue" >> "$PARTS_FILE"
      continue
    fi

    row_count=$(echo "$rows" | jq 'length' 2>/dev/null || echo 0)
    if [ "$row_count" -eq 0 ]; then
      echo "No query stats for database $db_id/instance $instance_id in the $STATS_WINDOW window (no traffic); skipping."
      continue
    fi

    echo "$rows" | jq -c '.[]' | while read -r row; do
      avg_latency_seconds=$(echo "$row" | jq -r '.AVG_LATENCY_SECONDS // "0"')
      execution_count=$(echo "$row" | jq -r '.EXECUTION_COUNT // "0"')
      avg_cpu_seconds=$(echo "$row" | jq -r '.AVG_CPU_SECONDS // "0"')
      query_text=$(echo "$row" | jq -r '.TEXT // "" | .[0:300]')

      avg_latency_ms=$(python3 -c "print(f'{float(\"$avg_latency_seconds\") * 1000:.2f}')" 2>/dev/null || echo "0")

      if python3 -c "exit(0 if float(\"$avg_latency_ms\") > float(\"$QUERY_LATENCY_THRESHOLD_MS\") else 1)" 2>/dev/null; then
        severity=3
        if python3 -c "exit(0 if float(\"$avg_latency_ms\") > float(\"$QUERY_LATENCY_THRESHOLD_MS\") * 2 else 1)" 2>/dev/null; then
          severity=4
        fi
        issue=$(jq -n \
          --arg title "High-latency query on database \`$db_id\` (instance \`$instance_id\`)" \
          --arg details "Query shape averaged ${avg_latency_ms}ms over $execution_count execution(s) (avg CPU ${avg_cpu_seconds}s) in the last $STATS_WINDOW, above the ${QUERY_LATENCY_THRESHOLD_MS}ms threshold. Query text (truncated): $query_text" \
          --argjson severity "$severity" \
          --arg expected "Mean query latency should stay below ${QUERY_LATENCY_THRESHOLD_MS}ms" \
          --arg actual "Mean query latency is ${avg_latency_ms}ms" \
          --arg next_steps "Review the query plan for missing secondary indexes or full table scans; consider adding an index or rewriting the query. Re-check via: gcloud spanner databases execute-sql $db_id --instance=$instance_id --project=$GCP_PROJECT_ID --sql=\"SELECT TEXT, AVG_LATENCY_SECONDS FROM SPANNER_SYS.${TABLE_NAME} ORDER BY AVG_LATENCY_SECONDS DESC LIMIT 5\"" \
          --arg instance "$instance_id" \
          --arg database "$db_id" \
          '{title:$title, details:$details, severity:$severity, expected:$expected, actual:$actual, next_steps:$next_steps, instance:$instance, database:$database}')
        echo "$issue" >> "$PARTS_FILE"
      fi
    done
  done
done

if [ -s "$PARTS_FILE" ]; then
  jq -s '.' "$PARTS_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$PARTS_FILE" /tmp/hlq_err.log

echo "High-latency query check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
