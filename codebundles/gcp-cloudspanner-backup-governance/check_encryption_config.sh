#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   REQUIRE_CMEK  (default false) -- if "true", flag databases not using
#                                     customer-managed encryption (CMEK)
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Describes each database and reads encryptionConfig.kmsKeyName
#      (absence means Google-managed encryption)
#   3) Only flags databases without CMEK when REQUIRE_CMEK=true
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${REQUIRE_CMEK:=false}"

OUTPUT_FILE="encryption_config_issues.json"

echo "Checking Cloud Spanner encryption configuration for project: $GCP_PROJECT_ID (REQUIRE_CMEK=$REQUIRE_CMEK)"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/encryption_config_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    db_detail=$(gcloud spanner databases describe "$db_name" --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    kms_key=$(echo "$db_detail" | jq -r '.encryptionConfig.kmsKeyName // empty')

    if [ -n "$kms_key" ]; then
      echo "Database $db_name (instance $instance_id): CMEK enabled, key=$kms_key"
      continue
    fi

    echo "Database $db_name (instance $instance_id): using Google-managed encryption (no kmsKeyName)"

    if [ "$REQUIRE_CMEK" = "true" ]; then
      printf '{"title":"Cloud Spanner database `%s` not using customer-managed encryption (instance `%s`)","details":"Database `%s` on instance `%s` in project `%s` uses Google-managed encryption (no encryptionConfig.kmsKeyName), but REQUIRE_CMEK is set to true for this project.","severity":3,"expected":"Database should be encrypted with a customer-managed encryption key (CMEK)","actual":"Database uses Google-managed default encryption","next_steps":"Recreate the database with a customer-managed encryption key: `gcloud spanner databases create %s --instance=%s --project=%s --kms-key=<key-resource-name>`. In-place migration to CMEK is not supported; a new database and data copy is required.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" "$db_name" >> /tmp/encryption_config_parts.jsonl
    fi
  done
done

if [ -s /tmp/encryption_config_parts.jsonl ]; then
  jq -s '.' /tmp/encryption_config_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/encryption_config_parts.jsonl

echo "Encryption configuration check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
