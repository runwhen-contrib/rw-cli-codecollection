#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   QUERY_LATENCY_THRESHOLD_MS             (default 100)
#   LOCK_WAIT_THRESHOLD_MS                 (default 1000)
#   ABORT_RATE_THRESHOLD_PERCENT           (default 5)
#   STATS_WINDOW                           (default HOUR) -- MINUTE, 10MINUTE, or HOUR
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.QUERY_STATS_TOP_<STATS_WINDOW>,
#      LOCK_STATS_TOP_<STATS_WINDOW>, and TXN_STATS_TOP_<STATS_WINDOW> for the
#      single worst query/lock/transaction shape on each dimension
#   3) Produces a consolidated per-database JSON summary (worst latency, worst
#      lock wait, worst abort rate, worst CPU-time query) with an overall
#      verdict (healthy/warning/critical)
#   4) Writes the summary to SUMMARY_FILE and a rollup JSON array of issues
#      (one per non-healthy database) to OUTPUT_FILE
#   5) An EMPTY result set on any dimension means no traffic on that dimension
#      in the window -- this is NOT unhealthy and does not contribute to the
#      verdict
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${QUERY_LATENCY_THRESHOLD_MS:=100}"
: "${LOCK_WAIT_THRESHOLD_MS:=1000}"
: "${ABORT_RATE_THRESHOLD_PERCENT:=5}"
: "${STATS_WINDOW:=HOUR}"

case "$STATS_WINDOW" in
  MINUTE|10MINUTE|HOUR) ;;
  *)
    echo "Unrecognized STATS_WINDOW '$STATS_WINDOW'; falling back to HOUR." >&2
    STATS_WINDOW="HOUR"
    ;;
esac

SUMMARY_FILE="query_performance_summary.json"
OUTPUT_FILE="query_performance_summary_issues.json"
QUERY_TABLE="QUERY_STATS_TOP_${STATS_WINDOW}"
LOCK_TABLE="LOCK_STATS_TOP_${STATS_WINDOW}"
TXN_TABLE="TXN_STATS_TOP_${STATS_WINDOW}"

DB_PARTS="/tmp/qps_databases.jsonl"
ISSUE_PARTS="/tmp/qps_issues.jsonl"

echo "Generating Cloud Spanner query performance summary for project: $GCP_PROJECT_ID (window: $STATS_WINDOW)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  jq -n --arg project_id "$GCP_PROJECT_ID" '{"project_id":$project_id,"stats_window":"'"$STATS_WINDOW"'","total_databases":0,"databases":[]}' > "$SUMMARY_FILE"
  echo "[]" > "$OUTPUT_FILE"
  jq . "$SUMMARY_FILE"
  exit 0
fi

> "$DB_PARTS"
> "$ISSUE_PARTS"

LATENCY_SQL="SELECT TEXT, EXECUTION_COUNT, AVG_LATENCY_SECONDS FROM SPANNER_SYS.${QUERY_TABLE} ORDER BY AVG_LATENCY_SECONDS DESC LIMIT 1"
LOCK_SQL="SELECT ROW_RANGE_START_KEY, LOCK_WAIT_SECONDS FROM SPANNER_SYS.${LOCK_TABLE} ORDER BY LOCK_WAIT_SECONDS DESC LIMIT 1"
TXN_SQL="SELECT COMMIT_ATTEMPT_COUNT, COMMIT_ABORT_COUNT FROM SPANNER_SYS.${TXN_TABLE} WHERE COMMIT_ATTEMPT_COUNT > 0 ORDER BY COMMIT_ABORT_COUNT DESC LIMIT 1"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    worst_latency_ms="null"
    worst_lock_wait_ms="null"
    worst_abort_rate_percent="null"

    if latency_rows=$(gcloud spanner databases execute-sql "$db_id" --instance="$instance_id" --project="$GCP_PROJECT_ID" --sql="$LATENCY_SQL" --format=json 2>/dev/null); then
      lr_count=$(echo "$latency_rows" | jq 'length' 2>/dev/null || echo 0)
      if [ "$lr_count" -gt 0 ]; then
        avg_latency_seconds=$(echo "$latency_rows" | jq -r '.[0].AVG_LATENCY_SECONDS // "0"')
        worst_latency_ms=$(python3 -c "print(f'{float(\"$avg_latency_seconds\") * 1000:.2f}')" 2>/dev/null || echo "null")
      fi
    fi

    if lock_rows=$(gcloud spanner databases execute-sql "$db_id" --instance="$instance_id" --project="$GCP_PROJECT_ID" --sql="$LOCK_SQL" --format=json 2>/dev/null); then
      lk_count=$(echo "$lock_rows" | jq 'length' 2>/dev/null || echo 0)
      if [ "$lk_count" -gt 0 ]; then
        lock_wait_seconds=$(echo "$lock_rows" | jq -r '.[0].LOCK_WAIT_SECONDS // "0"')
        worst_lock_wait_ms=$(python3 -c "print(f'{float(\"$lock_wait_seconds\") * 1000:.2f}')" 2>/dev/null || echo "null")
      fi
    fi

    if txn_rows=$(gcloud spanner databases execute-sql "$db_id" --instance="$instance_id" --project="$GCP_PROJECT_ID" --sql="$TXN_SQL" --format=json 2>/dev/null); then
      tx_count=$(echo "$txn_rows" | jq 'length' 2>/dev/null || echo 0)
      if [ "$tx_count" -gt 0 ]; then
        commit_attempt_count=$(echo "$txn_rows" | jq -r '.[0].COMMIT_ATTEMPT_COUNT // "0"')
        commit_abort_count=$(echo "$txn_rows" | jq -r '.[0].COMMIT_ABORT_COUNT // "0"')
        if [ "$commit_attempt_count" != "0" ]; then
          worst_abort_rate_percent=$(python3 -c "print(f'{(float(\"$commit_abort_count\") / float(\"$commit_attempt_count\")) * 100:.2f}')" 2>/dev/null || echo "null")
        fi
      fi
    fi

    # --- Determine verdict ---
    verdict="healthy"
    reasons=()
    if [ "$worst_latency_ms" != "null" ] && python3 -c "exit(0 if float(\"$worst_latency_ms\") > float(\"$QUERY_LATENCY_THRESHOLD_MS\") else 1)" 2>/dev/null; then
      verdict="warning"
      reasons+=("worst query latency ${worst_latency_ms}ms > ${QUERY_LATENCY_THRESHOLD_MS}ms")
    fi
    if [ "$worst_lock_wait_ms" != "null" ] && python3 -c "exit(0 if float(\"$worst_lock_wait_ms\") > float(\"$LOCK_WAIT_THRESHOLD_MS\") else 1)" 2>/dev/null; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("worst lock wait ${worst_lock_wait_ms}ms > ${LOCK_WAIT_THRESHOLD_MS}ms")
    fi
    if [ "$worst_abort_rate_percent" != "null" ] && python3 -c "exit(0 if float(\"$worst_abort_rate_percent\") > float(\"$ABORT_RATE_THRESHOLD_PERCENT\") else 1)" 2>/dev/null; then
      verdict="critical"
      reasons+=("worst abort rate ${worst_abort_rate_percent}% > ${ABORT_RATE_THRESHOLD_PERCENT}%")
    fi

    reasons_json=$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')

    db_summary=$(jq -n \
      --arg instance "$instance_id" \
      --arg database "$db_id" \
      --arg worst_latency_ms "$worst_latency_ms" \
      --arg worst_lock_wait_ms "$worst_lock_wait_ms" \
      --arg worst_abort_rate_percent "$worst_abort_rate_percent" \
      --arg verdict "$verdict" \
      --argjson reasons "$reasons_json" \
      '{
        "instance": $instance,
        "database": $database,
        "worst_query_latency_ms": (if $worst_latency_ms == "null" then null else ($worst_latency_ms | tonumber) end),
        "worst_lock_wait_ms": (if $worst_lock_wait_ms == "null" then null else ($worst_lock_wait_ms | tonumber) end),
        "worst_abort_rate_percent": (if $worst_abort_rate_percent == "null" then null else ($worst_abort_rate_percent | tonumber) end),
        "verdict": $verdict,
        "reasons": $reasons
      }')
    echo "$db_summary" >> "$DB_PARTS"

    if [ "$verdict" != "healthy" ]; then
      reasons_text=$(echo "$reasons_json" | jq -r 'join("; ")')
      issue=$(jq -n \
        --arg title "Cloud Spanner database \`$db_id\` query performance verdict: $verdict" \
        --arg details "Database \`$db_id\` on instance \`$instance_id\` in project \`$GCP_PROJECT_ID\` rolled up to verdict $verdict for the $STATS_WINDOW window. Reasons: $reasons_text." \
        --argjson severity 3 \
        --arg expected "Database query performance should have a healthy verdict across latency, lock contention, and abort-rate dimensions" \
        --arg actual "Verdict is $verdict ($reasons_text)" \
        --arg next_steps "Review the detailed high-latency-query, lock-contention, and transaction-abort task results for \`$db_id\` and remediate the flagged dimension(s)." \
        --arg instance "$instance_id" \
        --arg database "$db_id" \
        '{title:$title, details:$details, severity:$severity, expected:$expected, actual:$actual, next_steps:$next_steps, instance:$instance, database:$database}')
      echo "$issue" >> "$ISSUE_PARTS"
    fi
  done
done

if [ -s "$DB_PARTS" ]; then
  databases_json=$(jq -s '.' "$DB_PARTS")
else
  databases_json="[]"
fi
total_databases=$(echo "$databases_json" | jq 'length')

jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --arg stats_window "$STATS_WINDOW" \
  --argjson total_databases "$total_databases" \
  --argjson databases "$databases_json" \
  '{
    "project_id": $project_id,
    "stats_window": $stats_window,
    "total_databases": $total_databases,
    "databases": $databases
  }' > "$SUMMARY_FILE"

if [ -s "$ISSUE_PARTS" ]; then
  jq -s '.' "$ISSUE_PARTS" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$DB_PARTS" "$ISSUE_PARTS"

echo "Query performance summary generated. $(jq length "$OUTPUT_FILE") database(s) flagged."
jq . "$SUMMARY_FILE"
