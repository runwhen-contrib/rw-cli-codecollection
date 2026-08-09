#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   LONG_RUNNING_QUERY_THRESHOLD_SECONDS  (default 60) -- elapsed-time ceiling
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.OLDEST_ACTIVE_QUERIES
#      (a point-in-time table -- no STATS_WINDOW suffix)
#   3) Flags queries currently running longer than
#      LONG_RUNNING_QUERY_THRESHOLD_SECONDS, reporting elapsed time and text
#   4) An EMPTY result set means no queries are currently active -- this is
#      NOT an issue, it is skipped silently
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LONG_RUNNING_QUERY_THRESHOLD_SECONDS:=60}"

OUTPUT_FILE="long_running_queries_issues.json"
PARTS_FILE="/tmp/long_running_queries_parts.jsonl"

echo "Checking Cloud Spanner long-running active queries for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$PARTS_FILE"

SQL="SELECT SESSION_ID, START_TIME, TEXT, TEXT_TRUNCATED, TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), START_TIME, SECOND) AS ELAPSED_SECONDS FROM SPANNER_SYS.OLDEST_ACTIVE_QUERIES ORDER BY START_TIME ASC LIMIT 20"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    if ! rows=$(gcloud spanner databases execute-sql "$db_id" \
      --instance="$instance_id" \
      --project="$GCP_PROJECT_ID" \
      --sql="$SQL" \
      --format=json 2>/tmp/lrq_err.log); then
      err_msg=$(cat /tmp/lrq_err.log 2>/dev/null || echo "unknown error")
      issue=$(jq -n \
        --arg title "Cannot query OLDEST_ACTIVE_QUERIES for database \`$db_id\` (instance \`$instance_id\`)" \
        --arg details "gcloud spanner databases execute-sql against SPANNER_SYS.OLDEST_ACTIVE_QUERIES failed on database \`$db_id\`/instance \`$instance_id\`: $err_msg" \
        --argjson severity 3 \
        --arg expected "SPANNER_SYS.OLDEST_ACTIVE_QUERIES should be queryable with Spanner Database Reader access" \
        --arg actual "The execute-sql call failed" \
        --arg next_steps "Verify the service account has spanner.databases.select on \`$db_id\` and that Cloud Spanner API access is not blocked." \
        --arg instance "$instance_id" \
        --arg database "$db_id" \
        '{title:$title, details:$details, severity:$severity, expected:$expected, actual:$actual, next_steps:$next_steps, instance:$instance, database:$database}')
      echo "$issue" >> "$PARTS_FILE"
      continue
    fi

    # Normalize gcloud execute-sql --format=json {metadata,rows:[[...]]} into named-object rows
    rows=$(echo "$rows" | jq -c 'if type=="object" and has("rows") then [ .metadata.rowType.fields as $f | .rows[] | . as $r | reduce range(0; ($f|length)) as $i ({}; .[$f[$i].name] = $r[$i]) ] else . end')
    row_count=$(echo "$rows" | jq 'length' 2>/dev/null || echo 0)
    if [ "$row_count" -eq 0 ]; then
      echo "No active queries for database $db_id/instance $instance_id; skipping."
      continue
    fi

    echo "$rows" | jq -c '.[]' | while read -r row; do
      elapsed_seconds=$(echo "$row" | jq -r '.ELAPSED_SECONDS // "0"')
      session_id=$(echo "$row" | jq -r '.SESSION_ID // "" | .[0:120]')
      query_text=$(echo "$row" | jq -r '.TEXT // "" | .[0:300]')

      if python3 -c "exit(0 if float(\"$elapsed_seconds\") > float(\"$LONG_RUNNING_QUERY_THRESHOLD_SECONDS\") else 1)" 2>/dev/null; then
        severity=3
        if python3 -c "exit(0 if float(\"$elapsed_seconds\") > float(\"$LONG_RUNNING_QUERY_THRESHOLD_SECONDS\") * 3 else 1)" 2>/dev/null; then
          severity=4
        fi
        issue=$(jq -n \
          --arg title "Long-running active query on database \`$db_id\` (instance \`$instance_id\`)" \
          --arg details "Query in session \`$session_id\` has been running for ${elapsed_seconds}s, above the ${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}s threshold. Query text (truncated): $query_text" \
          --argjson severity "$severity" \
          --arg expected "Active queries should complete within ${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}s" \
          --arg actual "Query has been running for ${elapsed_seconds}s" \
          --arg next_steps "Review the query for missing indexes, unbounded scans, or lock waits. If it is stuck, consider cancelling the session. Re-check via: gcloud spanner databases execute-sql $db_id --instance=$instance_id --project=$GCP_PROJECT_ID --sql=\"SELECT SESSION_ID, TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), START_TIME, SECOND) AS ELAPSED_SECONDS FROM SPANNER_SYS.OLDEST_ACTIVE_QUERIES ORDER BY START_TIME ASC LIMIT 5\"" \
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
rm -f "$PARTS_FILE" /tmp/lrq_err.log

echo "Long-running query check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
