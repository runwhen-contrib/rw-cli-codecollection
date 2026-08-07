#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   RESOURCES  (comma-separated instance name filter; "All")
#
# This script fetches IAM policies for each Cloud SQL instance and flags risky
# bindings including allUsers/allAuthenticatedUsers access and over-broad roles.
# It writes a JSON array of issues to instance_iam_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

OUTPUT_FILE="instance_iam_issues.json"

echo "Checking Cloud SQL IAM policies for project: $GCP_PROJECT_ID"

# Over-broad roles considered too permissive at the instance level.
OVERBROAD_ROLES=("roles/owner" "roles/editor" "roles/cloudsql.admin")

instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No Cloud SQL instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
  filter=$(echo "$RESOURCES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | paste -sd'|' -)
  if [ -z "$filter" ]; then
    filter="NEVER_MATCHES"
  fi
  instances=$(echo "$instances" | jq --arg f "$filter" '[.[] | select(.name | test($f))]')
fi

if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No matching instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  name=$(echo "$inst" | jq -r '.name // "unknown"')

  echo "Checking IAM policy for $name"
  policy=$(gcloud sql instances get-iam-policy "$name" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

  # 1) Public / authenticated-everyone access on the instance.
  public=$(echo "$policy" | jq '[.bindings[]? | select(.members[]? == "allUsers" or .members[]? == "allAuthenticatedUsers")]')
  if [ "$(echo "$public" | jq length)" -gt 0 ]; then
    printf '{"title":"Cloud SQL instance `%s` grants public or unauthenticated access","details":"Cloud SQL instance `%s` in project `%s` has IAM bindings granting access to allUsers or allAuthenticatedUsers, exposing the instance to unauthorized access.","severity":3,"expected":"Only authorized principals should have access","actual":"Instance has allUsers or allAuthenticatedUsers bindings","next_steps":"Remove the public bindings: gcloud sql instances remove-iam-policy-binding %s --member=allUsers --role=<role> --project=%s. Grant access only to specific service accounts or users.","instance":"%s","issue_type":"public_iam_access"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  # 2) Over-broad roles bound to the instance.
  for role in "${OVERBROAD_ROLES[@]}"; do
    has_role=$(echo "$policy" | jq --arg r "$role" '[.bindings[]? | select(.role == $r)] | length')
    if [ "$has_role" -gt 0 ]; then
      printf '{"title":"Cloud SQL instance `%s` has over-broad role `%s`","details":"Cloud SQL instance `%s` in project `%s` has an over-broad IAM binding for role `%s`, granting excessive privileges.","severity":2,"expected":"Least-privilege roles should be used","actual":"Instance has over-broad role %s","next_steps":"Review and remove the over-broad role: gcloud sql instances remove-iam-policy-binding %s --member=<principal> --role=%s --project=%s. Grant only the minimal required roles.","instance":"%s","role":"%s","issue_type":"overbroad_role"}\n' \
        "$name" "$name" "$GCP_PROJECT_ID" "$role" "$role" "$name" "$role" "$GCP_PROJECT_ID" "$name" "$role" >> "$OUTPUT_FILE"
    fi
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "IAM check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
