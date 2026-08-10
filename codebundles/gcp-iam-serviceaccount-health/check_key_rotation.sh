#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          GCP project that houses the service accounts
#   SERVICE_ACCOUNT         (optional) scope checks to a single SA email
#   KEY_ROTATION_DAYS       (optional) max allowed key age in days (default 90)
#
# Detects service account JSON (USER_MANAGED) keys older than the configured
# rotation threshold and warns when rotation is overdue. Outputs a JSON array of
# issues to key_rotation_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="key_rotation_issues.json"
KEY_ROTATION_DAYS="${KEY_ROTATION_DAYS:-90}"
now_epoch=$(date +%s)

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
  echo "Checking key rotation for service account: $em"

  keys=$(gcloud iam service-accounts keys list --iam-account="$em" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo '[]')

  # Only USER_MANAGED keys are manually rotatable/auditable for hygiene
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    key_id=$(echo "$key" | jq -r '.name // .keyId // "unknown"')
    valid_after=$(echo "$key" | jq -r '.validAfterTime // ""')
    if [ -z "$valid_after" ] || [ "$valid_after" = "null" ]; then
      continue
    fi
    created_epoch=$(date -d "$valid_after" +%s 2>/dev/null || echo "")
    if [ -z "$created_epoch" ]; then
      continue
    fi
    age_days=$(( (now_epoch - created_epoch) / 86400 ))
    if [ "$age_days" -gt "$KEY_ROTATION_DAYS" ]; then
      severity=2
      if [ "$age_days" -gt $((KEY_ROTATION_DAYS * 2)) ]; then
        severity=3
      fi
      add_issue \
        "Service account \`${em}\` has an old key that has not been rotated" \
        "Service account \`${em}\` in project \`${GCP_PROJECT_ID}\` has key \`${key_id}\` created on ${valid_after} which is ${age_days} days old (max allowed: ${KEY_ROTATION_DAYS} days)." \
        "$severity" \
        "All USER_MANAGED keys should be rotated within ${KEY_ROTATION_DAYS} days" \
        "Key \`${key_id}\` is ${age_days} days old" \
        "Rotate the key by deleting it and creating a replacement, then update any consumers. Run: gcloud iam service-accounts keys delete ${key_id} --iam-account=${em} --project=${GCP_PROJECT_ID}"
    fi
  done < <(echo "$keys" | jq -c '.[] | select(.keyType == "USER_MANAGED")')
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Key rotation check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"
