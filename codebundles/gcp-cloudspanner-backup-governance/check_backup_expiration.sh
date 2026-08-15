#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   BACKUP_EXPIRY_WARNING_DAYS  (default 3) -- warn if a backup expires within
#                                               this many days
#
# This script:
#   1) Lists all Cloud Spanner instances, then backups within each instance
#   2) Inspects each backup's expire_time (and create_time for context)
#   3) Flags backups that are already expired, or expiring within
#      BACKUP_EXPIRY_WARNING_DAYS, leaving a retention gap
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${BACKUP_EXPIRY_WARNING_DAYS:=3}"

OUTPUT_FILE="backup_expiration_issues.json"

echo "Checking Cloud Spanner backup expiration for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/backup_expiration_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  backups=$(gcloud spanner backups list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
  backup_count=$(echo "$backups" | jq 'length')
  echo "Instance $instance_id: $backup_count backup(s)"

  echo "$backups" | jq -c '.[]' | while read -r bkp; do
    backup_id=$(echo "$bkp" | jq -r '.name' | awk -F/ '{print $NF}')
    db_name=$(echo "$bkp" | jq -r '.database // ""' | awk -F/ '{print $NF}')
    expire_time=$(echo "$bkp" | jq -r '.expireTime // empty')
    create_time=$(echo "$bkp" | jq -r '.createTime // empty')

    if [ -z "$expire_time" ]; then
      continue
    fi

    days_to_expiry=$(python3 -c "
import datetime
try:
    t = '$expire_time'.split('.')[0].replace('Z','')
    et = datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%S')
    now = datetime.datetime.utcnow()
    print((et - now).total_seconds() / 86400)
except Exception:
    print('null')
" 2>/dev/null || echo "null")

    if [ "$days_to_expiry" = "null" ]; then
      continue
    fi

    is_expired=$(python3 -c "print('true' if float('$days_to_expiry') < 0 else 'false')" 2>/dev/null || echo "false")

    if [ "$is_expired" = "true" ]; then
      printf '{"title":"Cloud Spanner backup `%s` has expired (database `%s`, instance `%s`)","details":"Backup `%s` for database `%s` on instance `%s` in project `%s` expired at %s (created %s), leaving a retention gap for this database.","severity":4,"expected":"Backups should be renewed or replaced before their expire_time","actual":"Backup expired at %s","next_steps":"Create a fresh backup for `%s` immediately and review the backup retention/expiration policy so backups are rotated before they expire.","instance":"%s","database":"%s","backup":"%s"}\n' \
        "$backup_id" "$db_name" "$instance_id" "$backup_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$expire_time" "$create_time" "$expire_time" "$db_name" "$instance_id" "$db_name" "$backup_id" >> /tmp/backup_expiration_parts.jsonl
      continue
    fi

    is_expiring_soon=$(python3 -c "print('true' if float('$days_to_expiry') <= float('$BACKUP_EXPIRY_WARNING_DAYS') else 'false')" 2>/dev/null || echo "false")
    days_rounded=$(python3 -c "print(f'{float(\"$days_to_expiry\"):.1f}')" 2>/dev/null || echo "$days_to_expiry")

    if [ "$is_expiring_soon" = "true" ]; then
      printf '{"title":"Cloud Spanner backup `%s` expiring soon (database `%s`, instance `%s`)","details":"Backup `%s` for database `%s` on instance `%s` in project `%s` expires in %s day(s) (expire_time %s), within the %s day warning window.","severity":3,"expected":"Backups should be replaced or extended more than %s day(s) before expiry","actual":"Backup expires in %s day(s)","next_steps":"Create a replacement backup for `%s` or extend the expire_time of this backup before it expires, to avoid a retention gap.","instance":"%s","database":"%s","backup":"%s"}\n' \
        "$backup_id" "$db_name" "$instance_id" "$backup_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$days_rounded" "$expire_time" "$BACKUP_EXPIRY_WARNING_DAYS" "$BACKUP_EXPIRY_WARNING_DAYS" "$days_rounded" "$db_name" "$instance_id" "$db_name" "$backup_id" >> /tmp/backup_expiration_parts.jsonl
    fi
  done
done

if [ -s /tmp/backup_expiration_parts.jsonl ]; then
  jq -s '.' /tmp/backup_expiration_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/backup_expiration_parts.jsonl

echo "Backup expiration check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
