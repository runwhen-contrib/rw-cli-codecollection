#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Reads the IAM policy on each instance and each database
#   3) Flags public bindings (allUsers, allAuthenticatedUsers)
#   4) Flags overly-permissive primitive roles (roles/owner, roles/editor)
#      bound directly on the instance or database
#   5) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="iam_access_issues.json"
PRIMITIVE_ROLES="roles/owner roles/editor"

echo "Checking Cloud Spanner IAM access configuration for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/iam_access_parts.jsonl

check_bindings() {
  # $1 = resource kind (instance|database), $2 = resource id label, $3 = instance id,
  # $4 = database id (may be empty for instance-level), $5 = bindings json array
  local kind="$1"
  local resource_label="$2"
  local instance_id="$3"
  local database_id="$4"
  local bindings="$5"

  echo "$bindings" | jq -c '.[]' 2>/dev/null | while read -r binding; do
    role=$(echo "$binding" | jq -r '.role // "unknown"')
    members=$(echo "$binding" | jq -c '.members // []')

    is_public=$(echo "$members" | jq -r '[.[] | select(. == "allUsers" or . == "allAuthenticatedUsers")] | length > 0')
    if [ "$is_public" = "true" ]; then
      printf '{"title":"Public IAM binding on Cloud Spanner %s `%s`","details":"%s `%s` in project `%s` grants role `%s` to a public member (allUsers or allAuthenticatedUsers). Members: %s.","severity":4,"expected":"No Cloud Spanner %s should grant access to allUsers or allAuthenticatedUsers","actual":"Role `%s` is bound to a public member","next_steps":"Remove the public IAM binding immediately: `gcloud spanner %ss remove-iam-policy-binding %s --project=%s --role=%s --member=<public-member>` and grant access to specific principals instead.","instance":"%s","database":"%s"}\n' \
        "$kind" "$resource_label" "$kind" "$resource_label" "$GCP_PROJECT_ID" "$role" "$(echo "$members" | jq -c .)" "$kind" "$role" "$kind" "$resource_label" "$GCP_PROJECT_ID" "$role" "$instance_id" "$database_id" >> /tmp/iam_access_parts.jsonl
    fi

    for primitive in $PRIMITIVE_ROLES; do
      if [ "$role" = "$primitive" ]; then
        printf '{"title":"Overly-permissive primitive role `%s` on Cloud Spanner %s `%s`","details":"%s `%s` in project `%s` grants primitive role `%s` directly to members: %s. Primitive roles are broad and not scoped to Spanner, which violates least-privilege access.","severity":3,"expected":"Use fine-grained Spanner IAM roles (e.g. roles/spanner.databaseReader) instead of primitive roles","actual":"Primitive role `%s` is bound directly on this resource","next_steps":"Replace `%s` with a scoped Spanner role such as roles/spanner.databaseUser or roles/spanner.viewer for the affected members.","instance":"%s","database":"%s"}\n' \
          "$role" "$kind" "$resource_label" "$kind" "$resource_label" "$GCP_PROJECT_ID" "$role" "$(echo "$members" | jq -c .)" "$role" "$role" "$instance_id" "$database_id" >> /tmp/iam_access_parts.jsonl
      fi
    done
  done
}

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  instance_policy=$(gcloud spanner instances get-iam-policy "$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  instance_bindings=$(echo "$instance_policy" | jq -c '.bindings // []')
  check_bindings "instance" "$instance_id" "$instance_id" "" "$instance_bindings"

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    db_policy=$(gcloud spanner databases get-iam-policy "$db_name" --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    db_bindings=$(echo "$db_policy" | jq -c '.bindings // []')
    check_bindings "database" "$db_name" "$instance_id" "$db_name" "$db_bindings"
  done
done

if [ -s /tmp/iam_access_parts.jsonl ]; then
  jq -s '.' /tmp/iam_access_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/iam_access_parts.jsonl

echo "IAM access check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
