#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          GCP project that houses the service accounts
#   SERVICE_ACCOUNT         (optional) scope checks to a single SA email
#
# Finds disabled service accounts that are still referenced in IAM policy
# bindings or used by resources, which can indicate drift. Outputs a JSON array
# of issues to disabled_sa_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="disabled_sa_issues.json"

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

# Get disabled status per service account
if [ -n "${SERVICE_ACCOUNT:-}" ]; then
  sa_list=$(gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')
  sa_list=$(echo "$sa_list" | jq '[.]')
else
  sa_list=$(gcloud iam service-accounts list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')
fi

project_policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')

while IFS= read -r sa; do
  email=$(echo "$sa" | jq -r '.email // ""')
  disabled=$(echo "$sa" | jq -r '.disabled // false')
  [ -z "$email" ] && continue

  if [ "$disabled" != "true" ]; then
    continue
  fi

  member="serviceAccount:${email}"

  # Is the disabled SA still referenced in project IAM policy?
  referenced=$(echo "$project_policy" | jq -r --arg m "$member" \
    '[.bindings[]? | .members[]? | select(. == $m)] | length')

  # Is the disabled SA still referenced in ITS OWN IAM policy by other members?
  sa_policy=$(gcloud iam service-accounts get-iam-policy "$email" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '{"bindings":[]}')
  sa_referenced=$(echo "$sa_policy" | jq '[.bindings[]? | .members[]? | select(test("^user:|^group:|^domain:|^serviceAccount:") )] | length')

  if [ "$referenced" -gt 0 ] || [ "$sa_referenced" -gt 0 ]; then
    echo "  Disabled service account $email is still referenced in IAM policies."
    add_issue \
      "Disabled service account \`${email}\` is still referenced in IAM policies" \
      "Disabled service account \`${email}\` in project \`${GCP_PROJECT_ID}\` is disabled but is still referenced by ${referenced} project-level binding(s) and ${sa_referenced} service-account-level binding(s), indicating drift." \
      2 \
      "Disabled service accounts should not remain referenced in IAM policy bindings or used by resources" \
      "Disabled service account \`${email}\` has ${referenced} project binding(s) and ${sa_referenced} SA-level binding(s)" \
      "Review why this service account is disabled yet still referenced. Remove stale bindings or re-enable/deprecate the SA intentionally. Run: gcloud projects get-iam-policy ${GCP_PROJECT_ID}"
  fi
done < <(echo "$sa_list" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_FILE"
echo "Disabled service account check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"
