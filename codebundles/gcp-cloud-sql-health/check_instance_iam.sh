#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   RESOURCES  (comma-separated instance name filter; "All") - accepted for
#              interface consistency; Cloud SQL IAM is governed at the project
#              level, so the check is project-scoped.
#
# Cloud SQL access is granted through *project*-level IAM roles (roles/cloudsql.*).
# Cloud SQL instances do NOT expose a per-instance IAM policy, so this script
# reads the project's IAM policy and flags any roles/cloudsql.* binding that
# grants access to the public (allUsers or allAuthenticatedUsers).
#
# It writes a JSON array of issues to instance_iam_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

OUTPUT_FILE="instance_iam_issues.json"

echo "Checking project IAM policy for public Cloud SQL access: $GCP_PROJECT_ID"

# Fetch the project IAM policy. Do NOT swallow the error: if the policy cannot
# be read (e.g. missing resourcemanager.projects.getIamPolicy), fail loudly
# instead of silently reporting a healthy result.
if ! policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json); then
  echo "ERROR: unable to read project IAM policy for $GCP_PROJECT_ID. The credential needs resourcemanager.projects.getIamPolicy." >&2
  exit 1
fi

> "$OUTPUT_FILE"

# Select roles/cloudsql.* bindings whose members include allUsers/allAuthenticatedUsers.
echo "$policy" | jq -c '.bindings[]? | select((.role | startswith("roles/cloudsql.")) and (any(.members[]?; . == "allUsers" or . == "allAuthenticatedUsers")))' | while read -r binding; do
  role=$(echo "$binding" | jq -r '.role')
  member=$(echo "$binding" | jq -r '[.members[] | select(. == "allUsers" or . == "allAuthenticatedUsers")] | join(", ")')
  printf '{"title":"Project `%s` grants public Cloud SQL access via `%s`","details":"Project `%s` has an IAM binding for role `%s` that includes %s, exposing Cloud SQL to unauthenticated or public principals.","severity":3,"expected":"Cloud SQL roles should not be granted to allUsers or allAuthenticatedUsers","actual":"Role %s is bound to %s","next_steps":"Remove the public member(s) from the binding: gcloud projects remove-iam-policy-binding %s --member=<allUsers|allAuthenticatedUsers> --role=%s. Grant Cloud SQL access only to specific users or service accounts.","project":"%s","role":"%s","issue_type":"public_iam_access"}\n' \
    "$GCP_PROJECT_ID" "$role" "$GCP_PROJECT_ID" "$role" "$member" "$role" "$member" "$GCP_PROJECT_ID" "$role" "$GCP_PROJECT_ID" "$role" >> "$OUTPUT_FILE"
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "IAM check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
