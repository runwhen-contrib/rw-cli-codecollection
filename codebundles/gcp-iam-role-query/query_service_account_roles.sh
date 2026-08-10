#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that provides the IAM context.
#   SERVICE_ACCOUNT  - Service account email to query role bindings for.
#
# Queries the full set of IAM role bindings attached to a service account:
#   1) project-level IAM bindings where the SA is a member
#   2) the service account's own IAM policy (who can impersonate/use it)
# Outputs human-readable findings to stdout and a JSON array of issues to
# OUTPUT_FILE. Issues are informational (severity 1) and only raised when the
# SA or its policy cannot be resolved; role findings themselves are reported on
# stdout, not as issues.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="service_account_role_issues.json"
issues_json='[]'

echo "Querying IAM roles for service account: ${SERVICE_ACCOUNT:-<unset>} in project: $GCP_PROJECT_ID"

if [ -z "${SERVICE_ACCOUNT:-}" ]; then
  echo "SERVICE_ACCOUNT is not set. This task requires a service account email."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Missing SERVICE_ACCOUNT for IAM role query in \`$GCP_PROJECT_ID\`" \
    --arg details "The SERVICE_ACCOUNT runtime variable is empty, so no bindings could be queried." \
    --arg severity "4" \
    --arg next_steps "Provide a service account email (e.g. sa@project.iam.gserviceaccount.com) via the SERVICE_ACCOUNT variable and re-run." \
    --arg expected "SERVICE_ACCOUNT should reference a valid service account email" \
    --arg actual "SERVICE_ACCOUNT was empty" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# --- 1) Project-level IAM bindings where the SA is a member ---
project_issues='[]'
if policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>err.log); then
  echo ""
  echo "=== Project-level roles granted to ${SERVICE_ACCOUNT} ==="
  matches=$(echo "$policy" | jq -c --arg sa "$SERVICE_ACCOUNT" '
    .bindings // [] |
    map(select((.members // []) | index($sa))) |
    [.[] | {role: .role, members: .members}]
  ')
  if [ "$(echo "$matches" | jq length)" -eq 0 ]; then
    echo "No project-level bindings found for ${SERVICE_ACCOUNT}."
  else
    echo "$matches" | jq .
  fi
else
  err_msg=$(cat err.log); rm -f err.log
  echo "WARNING: could not read project IAM policy: $err_msg"
  project_issues=$(echo "$project_issues" | jq \
    --arg title "Could not query project IAM policy for \`$GCP_PROJECT_ID\`" \
    --arg details "gcloud projects get-iam-policy failed: $err_msg" \
    --arg severity "1" \
    --arg next_steps "Verify the credentials have resourcemanager.projects.getIamPolicy permission." \
    --arg expected "IAM policy should be readable for the project" \
    --arg actual "get-iam-policy failed for the service account query" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
fi

# --- 2) Service account's own IAM policy ---
if sa_policy=$(gcloud iam service-accounts get-iam-policy "$SERVICE_ACCOUNT" --project="$GCP_PROJECT_ID" --format=json 2>err.log); then
  echo ""
  echo "=== IAM policy on the service account ${SERVICE_ACCOUNT} (who can use it) ==="
  echo "$sa_policy" | jq -c '.bindings // []'
else
  err_msg=$(cat err.log); rm -f err.log
  echo ""
  echo "No service account IAM policy could be retrieved: $err_msg"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No IAM policy found for service account \`$SERVICE_ACCOUNT\`" \
    --arg details "gcloud iam service-accounts get-iam-policy failed: $err_msg. The service account may not exist or is not accessible." \
    --arg severity "1" \
    --arg next_steps "Confirm the service account email is correct and that the credentials have iam.serviceAccounts.getIamPolicy permission." \
    --arg expected "The service account should exist and expose an IAM policy" \
    --arg actual "No IAM policy could be retrieved for the service account" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
fi

# Merge project-level informational issues into the main issue list
issues_json=$(jq -s 'add' <(echo "$issues_json") <(echo "$project_issues"))

echo "$issues_json" > "$OUTPUT_FILE"
echo "Service account role query completed. Found $(echo "$issues_json" | jq length) issue(s)."
