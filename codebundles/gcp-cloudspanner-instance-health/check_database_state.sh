#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   LONG_RUNNING_OPERATION_MINUTES  (default 60) -- age above which an incomplete
#                                                    schema/DDL operation is flagged
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Verifies each database is READY (READY_OPTIMIZING is treated as healthy)
#   3) Flags databases stuck in CREATING
#   4) Flags long-running, not-yet-done database operations (schema/DDL changes)
#      older than LONG_RUNNING_OPERATION_MINUTES
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LONG_RUNNING_OPERATION_MINUTES:=60}"

OUTPUT_FILE="database_state_issues.json"

echo "Checking Cloud Spanner database state for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/database_state_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
  db_count=$(echo "$databases" | jq 'length')
  echo "Instance $instance_id: $db_count database(s)"

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')
    state=$(echo "$db" | jq -r '.state // "UNKNOWN"')

    if [ "$state" = "CREATING" ]; then
      printf '{"title":"Cloud Spanner database `%s` stuck in CREATING on instance `%s`","details":"Database `%s` on instance `%s` in project `%s` is still in CREATING state.","severity":3,"expected":"Database creation should complete and reach READY","actual":"Database state is CREATING","next_steps":"Check `gcloud spanner databases describe %s --instance=%s --project=%s` and recent operations for creation errors.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" "$db_name" >> /tmp/database_state_parts.jsonl
    elif [ "$state" != "READY" ] && [ "$state" != "READY_OPTIMIZING" ]; then
      printf '{"title":"Cloud Spanner database `%s` in unexpected state `%s` on instance `%s`","details":"Database `%s` on instance `%s` in project `%s` reports state %s.","severity":2,"expected":"Database state should be READY or READY_OPTIMIZING","actual":"Database state is %s","next_steps":"Investigate via `gcloud spanner databases describe %s --instance=%s --project=%s`.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$state" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$state" "$state" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" "$db_name" >> /tmp/database_state_parts.jsonl
    fi

    # Long-running / stuck schema (DDL) operations for this database.
    ops=$(gcloud spanner operations list --instance="$instance_id" --database="$db_name" --project="$GCP_PROJECT_ID" --type=DATABASE --format=json 2>/dev/null || echo "[]")
    echo "$ops" | jq -c '.[] | select(.done != true)' 2>/dev/null | while read -r op; do
      op_name=$(echo "$op" | jq -r '.name // "unknown"')
      start_time=$(echo "$op" | jq -r '.metadata.startTime // empty')

      if [ -n "$start_time" ]; then
        age_minutes=$(python3 -c "
import datetime
try:
    st = datetime.datetime.strptime('$start_time'.split('.')[0].replace('Z',''), '%Y-%m-%dT%H:%M:%S')
    now = datetime.datetime.utcnow()
    print(int((now - st).total_seconds() / 60))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")
      else
        age_minutes=-1
      fi

      if [ "$age_minutes" != "-1" ] && [ "$age_minutes" -gt "$LONG_RUNNING_OPERATION_MINUTES" ]; then
        printf '{"title":"Long-running schema/DDL operation on database `%s` (instance `%s`)","details":"Operation `%s` on database `%s`/instance `%s` has been running for approximately %s minute(s), above the %s minute threshold.","severity":2,"expected":"Schema/DDL operations should complete within %s minutes","actual":"Operation has been running for %s minutes","next_steps":"Check `gcloud spanner operations describe %s --instance=%s --database=%s --project=%s` for progress; long DDL operations can indicate lock contention or an oversized migration.","instance":"%s","database":"%s"}\n' \
          "$db_name" "$instance_id" "$op_name" "$db_name" "$instance_id" "$age_minutes" "$LONG_RUNNING_OPERATION_MINUTES" "$LONG_RUNNING_OPERATION_MINUTES" "$age_minutes" "$op_name" "$instance_id" "$db_name" "$GCP_PROJECT_ID" "$instance_id" "$db_name" >> /tmp/database_state_parts.jsonl
      fi
    done
  done
done

if [ -s /tmp/database_state_parts.jsonl ]; then
  jq -s '.' /tmp/database_state_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/database_state_parts.jsonl

echo "Database state check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
