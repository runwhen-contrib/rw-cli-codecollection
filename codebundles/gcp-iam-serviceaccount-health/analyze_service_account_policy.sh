#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          GCP project that houses the service accounts
#   SERVICE_ACCOUNT         (optional) scope checks to a single SA email
#   PRIVILEGED_ROLES        (optional) comma-separated roles considered privileged
#
# Summarizes all service-account-level IAM role bindings in the project for a
# quick health overview and drift detection. Raises a severity-2 issue for each
# service account that has no role bindings at all (unused / drift candidate).
# Outputs a JSON array of issues to policy_analysis_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="policy_analysis_issues.json"
PRIVILEGED_ROLES="${PRIVILEGED_ROLES:-roles/owner,roles/editor}"

add_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local expected="$4"
  local actual="$5"
  local next_steps="$6"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --arg severity "$severity" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg next_steps "$next_steps" \
    '. + [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "expected": $expected,
       "actual": $actual,
       "next_steps": $next_steps
     }]')
}

issues_json='[]'
summary_json='[]'

if [ -n "${SERVICE_ACCOUNT:-}" ]; then
  sa_list=$(gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')
  sa_list=$(echo "$sa_list" | jq '[.]')
else
  sa_list=$(gcloud iam service-accounts list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')
fi

project_policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')

echo "Analyzing service account IAM policy for project: $GCP_PROJECT_ID"

while IFS= read -r sa; do
  [ -z "$sa" ] && continue
  email=$(echo "$sa" | jq -r '.email // ""')
  display_name=$(echo "$sa" | jq -r '.displayName // ""')
  disabled=$(echo "$sa" | jq -r '.disabled // false')
  [ -z "$email" ] && continue

  sa_policy=$(gcloud iam service-accounts get-iam-policy "$email" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')
  binding_count=$(echo "$sa_policy" | jq '[.bindings[]?] | length')
  member_count=$(echo "$sa_policy" | jq '[.bindings[]? | .members[]?] | length')

  # Record into the summary report for the human readable output
  sa_bindings=$(echo "$sa_policy" | jq '.bindings // []')
  summary_json=$(echo "$summary_json" | jq \
    --arg email "$email" \
    --arg display "$display_name" \
    --argjson disabled "$disabled" \
    --argjson bindings "$sa_bindings" \
    --argjson binding_count "$binding_count" \
    --argjson member_count "$member_count" \
    '. + [{
       "email": $email,
       "displayName": $display,
       "disabled": $disabled,
       "bindingCount": $binding_count,
       "memberCount": $member_count,
       "bindings": $bindings
     }]')

  if [ "$binding_count" -eq 0 ]; then
    add_issue \
      "Service account \`${email}\` has no IAM role bindings" \
      "Service account \`${email}\` in project \`${GCP_PROJECT_ID}\` has no role bindings at the service-account level. It may be unused drift." \
      2 \
      "Service accounts should either be in active use with defined roles or removed" \
      "Service account \`${email}\` has no IAM role bindings" \
      "Verify whether this service account is still needed. If unused, delete it or its role bindings. Run: gcloud iam service-accounts get-iam-policy ${email} --project=${GCP_PROJECT_ID}"
  fi

  echo "  ${email}: ${binding_count} binding(s), ${member_count} member(s)"
done < <(echo "$sa_list" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_FILE"
echo "$summary_json" > "service_account_policy_summary.json"

echo "Service account IAM policy analysis completed. Found $(jq length "$OUTPUT_FILE") issues."
echo "Summary of bindings:"
jq . "service_account_policy_summary.json"
