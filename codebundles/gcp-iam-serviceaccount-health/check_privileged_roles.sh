#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          GCP project that houses the service accounts
#   SERVICE_ACCOUNT         (optional) scope checks to a single SA email
#   PRIVILEGED_ROLES        (optional) comma-separated roles considered privileged
#
# Lists service accounts granted owner, editor, or other high-privilege roles at
# the project or service-account level and flags them for review. Outputs a JSON
# array of issues to privileged_roles_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="privileged_roles_issues.json"
PRIVILEGED_ROLES="${PRIVILEGED_ROLES:-roles/owner,roles/editor}"

IFS=',' read -ra PRIV_ROLES <<< "${PRIVILEGED_ROLES}"
priv_json=$(printf '%s\n' "${PRIV_ROLES[@]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)

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

# Resolve the list of service account emails to inspect
if [ -n "${SERVICE_ACCOUNT:-}" ]; then
  sa_emails=("$SERVICE_ACCOUNT")
else
  mapfile -t sa_emails < <(gcloud iam service-accounts list --project="$GCP_PROJECT_ID" --format='value(email)' 2>/dev/null || true)
fi

# Project-level IAM policy (bindings that grant roles directly to service accounts)
project_policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')

for em in "${sa_emails[@]}"; do
  em=$(echo "$em" | xargs)
  [ -z "$em" ] && continue
  member="serviceAccount:${em}"
  echo "Checking privileged roles for service account: $em"

  # Privileged roles granted at the project level to this SA
  proj_priv=$(echo "$project_policy" | jq -r --arg m "$member" --argjson r "$priv_json" \
    '[.bindings[]? | select(.members | index($m)) | select(.role | IN($r[])) | .role] | join(", ")')
  if [ -n "$proj_priv" ]; then
    add_issue \
      "Service account \`${em}\` has privileged project-level roles" \
      "Service account \`${em}\` in project \`${GCP_PROJECT_ID}\` is granted privileged role(s) at the project level: ${proj_priv}." \
      3 \
      "Service accounts should not be granted high-privilege roles such as \`${PRIVILEGED_ROLES}\`" \
      "Service account \`${em}\` holds privileged role(s): ${proj_priv}" \
      "Review the role bindings for \`${em}\`. Prefer least-privilege roles and dedicated roles that match the SA's actual workload needs. Run: gcloud projects get-iam-policy ${GCP_PROJECT_ID}"
  fi

  # Privileged roles granted at the service account level
  sa_policy=$(gcloud iam service-accounts get-iam-policy "$em" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')
  sa_priv=$(echo "$sa_policy" | jq -r --argjson r "$priv_json" \
    '[.bindings[]? | select(.role | IN($r[])) | .role] | join(", ")')
  if [ -n "$sa_priv" ]; then
    add_issue \
      "Service account \`${em}\` has privileged service-account-level roles" \
      "Service account \`${em}\` in project \`${GCP_PROJECT_ID}\` is granted privileged role(s) on its own IAM policy: ${sa_priv}." \
      3 \
      "Service accounts should not be granted high-privilege roles such as \`${PRIVILEGED_ROLES}\`" \
      "Service account \`${em}\` holds privileged role(s): ${sa_priv}" \
      "Review the IAM bindings on \`${em}\`. Limit who can impersonate or administer this service account. Run: gcloud iam service-accounts get-iam-policy ${em} --project=${GCP_PROJECT_ID}"
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Privileged role check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"
