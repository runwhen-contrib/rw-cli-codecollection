#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   STATS_WINDOW                       (default HOUR) -- MINUTE, 10MINUTE, or HOUR
#   CPU_TIME_SHARE_THRESHOLD_PERCENT   (default 25)   -- share of the top-20
#                                                         queries' total CPU time
#                                                         a single query shape can
#                                                         consume before it is
#                                                         flagged as a hot spot
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.QUERY_STATS_TOP_<STATS_WINDOW>
#      ordered by total CPU time (AVG_CPU_SECONDS * EXECUTION_COUNT) DESC
#   3) Flags query shapes consuming a disproportionate share
#      (> CPU_TIME_SHARE_THRESHOLD_PERCENT) of the combined CPU time of the
#      top-20 query shapes returned -- i.e. CPU hot spots
#   4) An EMPTY result set means no queries ran in the stats window -- this is
#      NOT an issue, it is skipped silently
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STATS_WINDOW:=HOUR}"
: "${CPU_TIME_SHARE_THRESHOLD_PERCENT:=25}"

case "$STATS_WINDOW" in
  MINUTE|10MINUTE|HOUR) ;;
  *)
    echo "Unrecognized STATS_WINDOW '$STATS_WINDOW'; falling back to HOUR." >&2
    STATS_WINDOW="HOUR"
    ;;
esac

OUTPUT_FILE="cpu_heavy_queries_issues.json"
TABLE_NAME="QUERY_STATS_TOP_${STATS_WINDOW}"
PARTS_FILE="/tmp/cpu_heavy_queries_parts.jsonl"

echo "Checking Cloud Spanner CPU-heavy queries for project: $GCP_PROJECT_ID (window: $STATS_WINDOW, table: $TABLE_NAME)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$PARTS_FILE"

SQL="SELECT TEXT, TEXT_TRUNCATED, EXECUTION_COUNT, AVG_CPU_SECONDS, AVG_LATENCY_SECONDS FROM SPANNER_SYS.${TABLE_NAME} ORDER BY AVG_CPU_SECONDS * EXECUTION_COUNT DESC LIMIT 20"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    if ! rows=$(gcloud spanner databases execute-sql "$db_id" \
      --instance="$instance_id" \
      --project="$GCP_PROJECT_ID" \
      --sql="$SQL" \
      --format=json 2>/tmp/cpu_err.log); then
      err_msg=$(cat /tmp/cpu_err.log 2>/dev/null || echo "unknown error")
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

    # Normalize gcloud execute-sql --format=json {metadata,rows:[[...]]} into named-object rows
    rows=$(echo "$rows" | jq -c 'if type=="object" and has("rows") then [ .metadata.rowType.fields as $f | .rows[] | . as $r | reduce range(0; ($f|length)) as $i ({}; .[$f[$i].name] = $r[$i]) ] else . end')
    row_count=$(echo "$rows" | jq 'length' 2>/dev/null || echo 0)
    if [ "$row_count" -eq 0 ]; then
      echo "No query stats for database $db_id/instance $instance_id in the $STATS_WINDOW window (no traffic); skipping."
      continue
    fi

    # Total CPU-seconds consumed by each returned query shape (avg_cpu * executions),
    # and the sum across all returned shapes, used to compute each shape's CPU share.
    total_cpu_all=$(echo "$rows" | jq '[.[] | ((.AVG_CPU_SECONDS // 0 | tonumber) * (.EXECUTION_COUNT // 0 | tonumber))] | add // 0')

    if python3 -c "exit(0 if float(\"$total_cpu_all\") <= 0 else 1)" 2>/dev/null; then
      echo "No measurable CPU time for database $db_id/instance $instance_id; skipping."
      continue
    fi

    echo "$rows" | jq -c '.[]' | while read -r row; do
      avg_cpu_seconds=$(echo "$row" | jq -r '.AVG_CPU_SECONDS // "0"')
      execution_count=$(echo "$row" | jq -r '.EXECUTION_COUNT // "0"')
      avg_latency_seconds=$(echo "$row" | jq -r '.AVG_LATENCY_SECONDS // "0"')
      query_text=$(echo "$row" | jq -r '.TEXT // "" | .[0:300]')

      total_cpu_query=$(python3 -c "print(f'{float(\"$avg_cpu_seconds\") * float(\"$execution_count\"):.4f}')" 2>/dev/null || echo "0")
      cpu_share_percent=$(python3 -c "print(f'{(float(\"$total_cpu_query\") / float(\"$total_cpu_all\")) * 100:.2f}')" 2>/dev/null || echo "0")

      if python3 -c "exit(0 if float(\"$cpu_share_percent\") > float(\"$CPU_TIME_SHARE_THRESHOLD_PERCENT\") else 1)" 2>/dev/null; then
        severity=3
        if python3 -c "exit(0 if float(\"$cpu_share_percent\") > 50 else 1)" 2>/dev/null; then
          severity=4
        fi
        issue=$(jq -n \
          --arg title "CPU-heavy query hot spot on database \`$db_id\` (instance \`$instance_id\`)" \
          --arg details "Query shape consumed ~${total_cpu_query}s of CPU (avg ${avg_cpu_seconds}s x $execution_count execution(s), avg latency ${avg_latency_seconds}s), which is ${cpu_share_percent}% of the combined CPU time of the top query shapes in the last $STATS_WINDOW -- above the ${CPU_TIME_SHARE_THRESHOLD_PERCENT}% share threshold. Query text (truncated): $query_text" \
          --argjson severity "$severity" \
          --arg expected "No single query shape should consume more than ${CPU_TIME_SHARE_THRESHOLD_PERCENT}% of the top query shapes' combined CPU time" \
          --arg actual "Query shape consumes ${cpu_share_percent}% of combined CPU time" \
          --arg next_steps "This query shape is a CPU hot spot. Review its query plan for full scans or expensive joins/aggregations, add a covering index, or reduce call frequency. Re-check via: gcloud spanner databases execute-sql $db_id --instance=$instance_id --project=$GCP_PROJECT_ID --sql=\"SELECT TEXT, AVG_CPU_SECONDS, EXECUTION_COUNT FROM SPANNER_SYS.${TABLE_NAME} ORDER BY AVG_CPU_SECONDS * EXECUTION_COUNT DESC LIMIT 5\"" \
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
rm -f "$PARTS_FILE" /tmp/cpu_err.log

echo "CPU-heavy query check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
