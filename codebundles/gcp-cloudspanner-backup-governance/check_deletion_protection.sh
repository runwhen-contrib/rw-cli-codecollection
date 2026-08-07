#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Checks instance-level deletion protection (enableDropProtection), where
#      the field is present in the API response for this instance
#   3) Checks database-level deletion protection (enableDropProtection),
#      defaulting to disabled if the field is absent (matches the API default)
#   4) Flags instances/databases with deletion protection disabled
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="deletion_protection_issues.json"

echo "Checking Cloud Spanner deletion protection for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/deletion_protection_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  instance_detail=$(gcloud spanner instances describe "$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  has_instance_field=$(echo "$instance_detail" | jq -r 'has("enableDropProtection")')

  if [ "$has_instance_field" = "true" ]; then
    instance_protected=$(echo "$instance_detail" | jq -r '.enableDropProtection')
    if [ "$instance_protected" = "false" ]; then
      printf '{"title":"Cloud Spanner instance `%s` deletion protection is disabled","details":"Instance `%s` in project `%s` has deletion protection (enableDropProtection) disabled, risking accidental deletion of the instance and all its databases.","severity":3,"expected":"Instance deletion protection should be enabled","actual":"enableDropProtection is false","next_steps":"Enable deletion protection via `gcloud spanner instances update %s --project=%s --enable-drop-protection`.","instance":"%s"}\n' \
        "$instance_id" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" >> /tmp/deletion_protection_parts.jsonl
    fi
  else
    echo "Instance $instance_id: enableDropProtection field not present in API response, skipping instance-level check."
  fi

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')
    db_protected=$(echo "$db" | jq -r '.enableDropProtection // false')

    if [ "$db_protected" = "false" ]; then
      printf '{"title":"Cloud Spanner database `%s` deletion protection is disabled (instance `%s`)","details":"Database `%s` on instance `%s` in project `%s` has deletion protection (enableDropProtection) disabled, risking accidental deletion of the database.","severity":2,"expected":"Database deletion protection should be enabled","actual":"enableDropProtection is false","next_steps":"Enable deletion protection via `gcloud spanner databases update %s --instance=%s --project=%s --enable-drop-protection`.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" "$db_name" >> /tmp/deletion_protection_parts.jsonl
    fi
  done
done

if [ -s /tmp/deletion_protection_parts.jsonl ]; then
  jq -s '.' /tmp/deletion_protection_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/deletion_protection_parts.jsonl

echo "Deletion protection check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
