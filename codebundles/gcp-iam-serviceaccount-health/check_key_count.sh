#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          GCP project that houses the service accounts
#   SERVICE_ACCOUNT         (optional) scope checks to a single SA email
#   MAX_KEYS_PER_SA         (optional) max active USER_MANAGED keys (default 5)
#
# Flags service accounts holding more than the allowed number of active
# (USER_MANAGED) keys, which broadens the attack surface. Outputs a JSON array
# of issues to key_count_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="key_count_issues.json"
MAX_KEYS_PER_SA="${MAX_KEYS_PER_SA:-5}"

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

if [ -n "${SERVICE_ACCOUNT:-}" ]; then
  sa_emails=("$SERVICE_ACCOUNT")
else
  mapfile -t sa_emails < <(gcloud iam service-accounts list --project="$GCP_PROJECT_ID" --format='value(email)' 2>/dev/null || true)
fi

for em in "${sa_emails[@]}"; do
  em=$(echo "$em" | xargs)
  [ -z "$em" ] && continue
  echo "Checking key count for service account: $em"

  keys=$(gcloud iam service-accounts keys list --iam-account="$em" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')
  key_count=$(echo "$keys" | jq '[.[] | select(.keyType == "USER_MANAGED")] | length')

  if [ "$key_count" -gt "$MAX_KEYS_PER_SA" ]; then
    add_issue \
      "Service account \`${em}\` has too many active keys" \
      "Service account \`${em}\` in project \`${GCP_PROJECT_ID}\` has ${key_count} active USER_MANAGED keys (max allowed: ${MAX_KEYS_PER_SA}). Each key increases the attack surface and complicates rotation." \
      3 \
      "Service accounts should have at most ${MAX_KEYS_PER_SA} active keys" \
      "Service account \`${em}\` has ${key_count} active keys" \
      "Remove unused keys and audit remaining ones. Run: gcloud iam service-accounts keys list --iam-account=${em} --project=${GCP_PROJECT_ID} to review keys"
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Key count check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"
