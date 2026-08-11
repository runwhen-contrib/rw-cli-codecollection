#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   BACKUP_RECENCY_THRESHOLD_HOURS  (default 24) -- max age of the most recent
#                                                    backup before an issue is raised
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Lists backups per instance and matches them to their source database
#   3) Flags databases with no backup at all, or whose most recent backup is
#      older than BACKUP_RECENCY_THRESHOLD_HOURS
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${BACKUP_RECENCY_THRESHOLD_HOURS:=24}"

OUTPUT_FILE="backup_recency_issues.json"

echo "Checking Cloud Spanner backup recency for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>err.log) || {
  err_msg=$(cat err.log 2>/dev/null || echo "unknown error")
  rm -f err.log
  jq -n \
    --arg title "Cannot List Cloud Spanner Instances for \`$GCP_PROJECT_ID\`" \
    --arg details "gcloud spanner instances list failed: $err_msg" \
    --arg expected "Cloud Spanner instances should be listable via gcloud" \
    --arg actual "The gcloud spanner instances list call failed" \
    --arg next_steps "Verify the service account has roles/spanner.viewer and that the Spanner API is enabled for the project" \
    '[{"title":$title,"details":$details,"severity":3,"expected":$expected,"actual":$actual,"next_steps":$next_steps}]' > "$OUTPUT_FILE"
  jq . "$OUTPUT_FILE"
  exit 0
}
rm -f err.log

instance_count=$(echo "$instances" | jq 'length')
echo "Found $instance_count Cloud Spanner instance(s)."

if [ "$instance_count" -eq 0 ]; then
  echo "[]" > "$OUTPUT_FILE"
  echo "No Cloud Spanner instances found in project $GCP_PROJECT_ID."
  jq . "$OUTPUT_FILE"
  exit 0
fi

> /tmp/backup_recency_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
  backups=$(gcloud spanner backups list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')
    db_full_name=$(echo "$db" | jq -r '.name')

    latest_create_time=$(echo "$backups" | jq -r --arg db "$db_full_name" \
      '[.[] | select(.database == $db)] | sort_by(.createTime) | last | .createTime // empty')

    if [ -z "$latest_create_time" ]; then
      printf '{"title":"No backup found for Cloud Spanner database `%s` (instance `%s`)","details":"No backups matching database `%s` were found on instance `%s` in project `%s`. Without a backup the database cannot be restored if data is lost or corrupted.","severity":3,"expected":"Every database should have at least one backup","actual":"No backups exist for this database","next_steps":"Create a backup via `gcloud spanner backups create` or configure a backup schedule for database `%s` on instance `%s`.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$db_name" "$instance_id" "$instance_id" "$db_name" >> /tmp/backup_recency_parts.jsonl
      continue
    fi

    age_hours=$(python3 -c "
import datetime
try:
    t = '$latest_create_time'.split('.')[0].replace('Z','')
    st = datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%S')
    now = datetime.datetime.utcnow()
    print((now - st).total_seconds() / 3600)
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")

    if [ "$age_hours" = "-1" ]; then
      continue
    fi

    is_stale=$(python3 -c "print('true' if float('$age_hours') > float('$BACKUP_RECENCY_THRESHOLD_HOURS') else 'false')" 2>/dev/null || echo "false")
    age_hours_rounded=$(python3 -c "print(f'{float(\"$age_hours\"):.1f}')" 2>/dev/null || echo "$age_hours")

    if [ "$is_stale" = "true" ]; then
      printf '{"title":"Cloud Spanner database `%s` backup is stale (instance `%s`)","details":"The most recent backup for database `%s` on instance `%s` in project `%s` was created %s hour(s) ago, exceeding the %s hour recency threshold.","severity":2,"expected":"Most recent backup should be less than %s hour(s) old","actual":"Most recent backup is %s hour(s) old","next_steps":"Investigate why backups have not run recently for `%s` (schedule, quota, or permission issues) and trigger a fresh backup.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$age_hours_rounded" "$BACKUP_RECENCY_THRESHOLD_HOURS" "$BACKUP_RECENCY_THRESHOLD_HOURS" "$age_hours_rounded" "$db_name" "$instance_id" "$db_name" >> /tmp/backup_recency_parts.jsonl
    fi
  done
done

if [ -s /tmp/backup_recency_parts.jsonl ]; then
  jq -s '.' /tmp/backup_recency_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/backup_recency_parts.jsonl

echo "Backup recency check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
