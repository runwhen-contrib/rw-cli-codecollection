#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   ABORT_RATE_THRESHOLD_PERCENT  (default 5)    -- commit-abort/retry % ceiling
#   STATS_WINDOW                  (default HOUR) -- MINUTE, 10MINUTE, or HOUR
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.TXN_STATS_TOP_<STATS_WINDOW>
#      ordered by COMMIT_ABORT_COUNT DESC
#   3) Flags transaction shapes whose abort rate
#      (COMMIT_ABORT_COUNT / COMMIT_ATTEMPT_COUNT) exceeds
#      ABORT_RATE_THRESHOLD_PERCENT, which indicates contention or hotspotting
#   4) An EMPTY result set means no committed transactions were recorded in the
#      stats window -- this is NOT an issue, it is skipped silently
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ABORT_RATE_THRESHOLD_PERCENT:=5}"
: "${STATS_WINDOW:=HOUR}"

case "$STATS_WINDOW" in
  MINUTE|10MINUTE|HOUR) ;;
  *)
    echo "Unrecognized STATS_WINDOW '$STATS_WINDOW'; falling back to HOUR." >&2
    STATS_WINDOW="HOUR"
    ;;
esac

OUTPUT_FILE="transaction_aborts_issues.json"
TABLE_NAME="TXN_STATS_TOP_${STATS_WINDOW}"
PARTS_FILE="/tmp/transaction_aborts_parts.jsonl"

echo "Checking Cloud Spanner transaction abort rate for project: $GCP_PROJECT_ID (window: $STATS_WINDOW, table: $TABLE_NAME)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$PARTS_FILE"

SQL="SELECT FPRINT, COMMIT_ATTEMPT_COUNT, COMMIT_ABORT_COUNT, AVG_PARTICIPANTS, AVG_TOTAL_LATENCY_SECONDS, READ_COLUMNS, WRITE_CONSTRUCTIVE_COLUMNS FROM SPANNER_SYS.${TABLE_NAME} WHERE COMMIT_ATTEMPT_COUNT > 0 ORDER BY COMMIT_ABORT_COUNT DESC LIMIT 20"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    if ! rows=$(gcloud spanner databases execute-sql "$db_id" \
      --instance="$instance_id" \
      --project="$GCP_PROJECT_ID" \
      --sql="$SQL" \
      --format=json 2>/tmp/txn_err.log); then
      err_msg=$(cat /tmp/txn_err.log 2>/dev/null || echo "unknown error")
      issue=$(jq -n \
        --arg title "Cannot query TXN_STATS for database \`$db_id\` (instance \`$instance_id\`)" \
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
      echo "No transaction stats for database $db_id/instance $instance_id in the $STATS_WINDOW window (no committed transactions); skipping."
      continue
    fi

    echo "$rows" | jq -c '.[]' | while read -r row; do
      commit_attempt_count=$(echo "$row" | jq -r '.COMMIT_ATTEMPT_COUNT // "0"')
      commit_abort_count=$(echo "$row" | jq -r '.COMMIT_ABORT_COUNT // "0"')
      avg_participants=$(echo "$row" | jq -r '.AVG_PARTICIPANTS // "0"')
      read_columns=$(echo "$row" | jq -c '.READ_COLUMNS // []')
      write_columns=$(echo "$row" | jq -c '.WRITE_CONSTRUCTIVE_COLUMNS // []')

      if [ "$commit_attempt_count" = "0" ] || [ -z "$commit_attempt_count" ]; then
        continue
      fi

      abort_rate_percent=$(python3 -c "print(f'{(float(\"$commit_abort_count\") / float(\"$commit_attempt_count\")) * 100:.2f}')" 2>/dev/null || echo "0")

      if python3 -c "exit(0 if float(\"$abort_rate_percent\") > float(\"$ABORT_RATE_THRESHOLD_PERCENT\") else 1)" 2>/dev/null; then
        severity=2
        if python3 -c "exit(0 if float(\"$abort_rate_percent\") > float(\"$ABORT_RATE_THRESHOLD_PERCENT\") * 3 else 1)" 2>/dev/null; then
          severity=3
        fi
        issue=$(jq -n \
          --arg title "Elevated transaction abort rate on database \`$db_id\` (instance \`$instance_id\`)" \
          --arg details "Transaction shape aborted ${commit_abort_count} of ${commit_attempt_count} commit attempt(s) (${abort_rate_percent}%) in the last $STATS_WINDOW, above the ${ABORT_RATE_THRESHOLD_PERCENT}% threshold. Avg participants: $avg_participants. Read columns: $read_columns. Write columns: $write_columns." \
          --argjson severity "$severity" \
          --arg expected "Transaction abort/commit-retry rate should stay below ${ABORT_RATE_THRESHOLD_PERCENT}%" \
          --arg actual "Abort rate is ${abort_rate_percent}%" \
          --arg next_steps "High abort rates usually indicate write contention or hotspotting on the same row range. Review the read/write column set for this transaction shape and consider reducing transaction scope, batching, or a different key strategy. Re-check via: gcloud spanner databases execute-sql $db_id --instance=$instance_id --project=$GCP_PROJECT_ID --sql=\"SELECT COMMIT_ATTEMPT_COUNT, COMMIT_ABORT_COUNT FROM SPANNER_SYS.${TABLE_NAME} ORDER BY COMMIT_ABORT_COUNT DESC LIMIT 5\"" \
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
rm -f "$PARTS_FILE" /tmp/txn_err.log

echo "Transaction abort rate check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
