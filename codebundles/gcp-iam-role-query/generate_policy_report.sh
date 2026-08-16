#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that provides the IAM context.
#
# Produces a consolidated report of all IAM bindings in the project grouped by
# principal and role for on-demand auditing. The report is printed to stdout and
# informational (severity 1) issues are written only when the policy cannot be
# retrieved.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="policy_report_issues.json"
issues_json='[]'

echo "Generating IAM policy report for project: $GCP_PROJECT_ID"

if ! policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>err.log); then
  err_msg=$(cat err.log); rm -f err.log
  echo "Could not retrieve project IAM policy: $err_msg"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No IAM policy found for project \`$GCP_PROJECT_ID\`" \
    --arg details "gcloud projects get-iam-policy failed: $err_msg" \
    --arg severity "1" \
    --arg next_steps "Verify the credentials have resourcemanager.projects.getIamPolicy permission." \
    --arg expected "The project IAM policy should be readable" \
    --arg actual "No IAM policy could be retrieved for the project" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Policy report generation completed. Found 1 issue."
  exit 0
fi

# Group bindings by principal, then list the roles granted to each principal.
echo ""
echo "=== IAM bindings grouped by principal ==="
echo "$policy" | jq -r '
  .bindings // [] |
  . as $bs |
  ( [.[].members[]] | unique[] ) as $principal |
  { principal: $principal,
    roles: [ $bs[] | select((.members // []) | index($principal)) | .role ] }
' | jq -s '
  group_by(.principal) |
  map({principal: .[0].principal, roles: ([.[].roles[]] | unique)}) |
  sort_by(.principal)
' | jq -r '.[] | "\(.principal): \(.roles | join(", "))"'
echo ""

echo "=== Bindings summary ==="
echo "$policy" | jq -c '{etag: .etag, total_bindings: (.bindings // [] | length), total_members: ([.bindings[].members[]] | length), bindings: [.bindings[] | {role: .role, members: .members}]}' | tee policy_report_summary.json

# Persist a machine-readable copy alongside the issues file for the runbook.
echo "$policy" | jq -c '{etag: .etag, bindings: .bindings}' > project_iam_policy.json

echo "$issues_json" > "$OUTPUT_FILE"
echo "Policy report generation completed. Found $(echo "$issues_json" | jq length) issue(s)."
