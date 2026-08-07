#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   LOCK_WAIT_THRESHOLD_MS  (default 1000) -- total lock wait time (ms) ceiling
#                                              for a row-key range
#   STATS_WINDOW            (default HOUR) -- MINUTE, 10MINUTE, or HOUR
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) For each database, queries SPANNER_SYS.LOCK_STATS_TOP_<STATS_WINDOW>
#      ordered by LOCK_WAIT_SECONDS DESC
#   3) Flags contended row-key ranges whose total lock wait time exceeds
#      LOCK_WAIT_THRESHOLD_MS, reporting the sample lock-requesting columns
#   4) An EMPTY result set means no lock contention was recorded in the stats
#      window -- this is NOT an issue, it is skipped silently
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LOCK_WAIT_THRESHOLD_MS:=1000}"
: "${STATS_WINDOW:=HOUR}"

case "$STATS_WINDOW" in
  MINUTE|10MINUTE|HOUR) ;;
  *)
    echo "Unrecognized STATS_WINDOW '$STATS_WINDOW'; falling back to HOUR." >&2
    STATS_WINDOW="HOUR"
    ;;
esac

OUTPUT_FILE="lock_contention_issues.json"
TABLE_NAME="LOCK_STATS_TOP_${STATS_WINDOW}"
PARTS_FILE="/tmp/lock_contention_parts.jsonl"

echo "Checking Cloud Spanner lock contention for project: $GCP_PROJECT_ID (window: $STATS_WINDOW, table: $TABLE_NAME)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$PARTS_FILE"

SQL="SELECT ROW_RANGE_START_KEY, LOCK_WAIT_SECONDS, SAMPLE_LOCK_REQUESTS FROM SPANNER_SYS.${TABLE_NAME} ORDER BY LOCK_WAIT_SECONDS DESC LIMIT 20"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_id=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    if ! rows=$(gcloud spanner databases execute-sql "$db_id" \
      --instance="$instance_id" \
      --project="$GCP_PROJECT_ID" \
      --sql="$SQL" \
      --format=json 2>/tmp/lock_err.log); then
      err_msg=$(cat /tmp/lock_err.log 2>/dev/null || echo "unknown error")
      issue=$(jq -n \
        --arg title "Cannot query LOCK_STATS for database \`$db_id\` (instance \`$instance_id\`)" \
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
      echo "No lock stats for database $db_id/instance $instance_id in the $STATS_WINDOW window (no contention); skipping."
      continue
    fi

    echo "$rows" | jq -c '.[]' | while read -r row; do
      lock_wait_seconds=$(echo "$row" | jq -r '.LOCK_WAIT_SECONDS // "0"')
      row_range_key=$(echo "$row" | jq -r '.ROW_RANGE_START_KEY // "" | .[0:200]')
      sample_requests=$(echo "$row" | jq -c '.SAMPLE_LOCK_REQUESTS // []')

      lock_wait_ms=$(python3 -c "print(f'{float(\"$lock_wait_seconds\") * 1000:.2f}')" 2>/dev/null || echo "0")

      if python3 -c "exit(0 if float(\"$lock_wait_ms\") > float(\"$LOCK_WAIT_THRESHOLD_MS\") else 1)" 2>/dev/null; then
        severity=2
        if python3 -c "exit(0 if float(\"$lock_wait_ms\") > float(\"$LOCK_WAIT_THRESHOLD_MS\") * 5 else 1)" 2>/dev/null; then
          severity=3
        fi
        issue=$(jq -n \
          --arg title "Contended row-key range on database \`$db_id\` (instance \`$instance_id\`)" \
          --arg details "Row range starting at key \`$row_range_key\` accumulated ${lock_wait_ms}ms of lock wait time in the last $STATS_WINDOW, above the ${LOCK_WAIT_THRESHOLD_MS}ms threshold. Sample lock-requesting columns/transactions: $sample_requests" \
          --argjson severity "$severity" \
          --arg expected "Row-key ranges should accumulate below ${LOCK_WAIT_THRESHOLD_MS}ms of lock wait time per window" \
          --arg actual "Lock wait time is ${lock_wait_ms}ms" \
          --arg next_steps "Investigate write hotspotting on this key range -- consider a different primary key strategy (e.g. UUID/hash prefix instead of monotonically increasing keys) or splitting the writes. Re-check via: gcloud spanner databases execute-sql $db_id --instance=$instance_id --project=$GCP_PROJECT_ID --sql=\"SELECT ROW_RANGE_START_KEY, LOCK_WAIT_SECONDS FROM SPANNER_SYS.${TABLE_NAME} ORDER BY LOCK_WAIT_SECONDS DESC LIMIT 5\"" \
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
rm -f "$PARTS_FILE" /tmp/lock_err.log

echo "Lock contention check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
