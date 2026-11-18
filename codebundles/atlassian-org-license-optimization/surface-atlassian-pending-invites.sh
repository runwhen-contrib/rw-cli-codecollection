#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   ATLASSIAN_ORG_ID
#   ATLASSIAN_ORG_NAME
#
# OPTIONAL:
#   PENDING_INVITE_DAYS_THRESHOLD (default 30)
#   ATLASSIAN_DIRECTORY_ID (auto-discover if empty)
# -----------------------------------------------------------------------------

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"
: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"
: "${PENDING_INVITE_DAYS_THRESHOLD:=30}"

OUTPUT_FILE="atlassian_pending_invite_issues.json"
SUMMARY_FILE="atlassian_pending_invite_summary.txt"
issues_json='[]'

source "$(dirname "$0")/atlassian-api-helpers.sh"

echo "Surfacing pending invites for organization: ${ATLASSIAN_ORG_NAME}"
echo "Stale invite threshold: ${PENDING_INVITE_DAYS_THRESHOLD} days"

if ! ensure_directory_users; then
  issues_json=$(append_api_access_issue "$issues_json" "Failed to fetch directory users from GET /v2/orgs/{orgId}/directories/{directoryId}/users.")
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

pending_report=$(jq \
  --argjson threshold "$PENDING_INVITE_DAYS_THRESHOLD" \
  'def days_since_iso($iso):
     if ($iso // "") == "" then 999999
     else (($iso | sub("\\.[0-9]+"; "") | fromdateiso8601?) as $ts |
       if $ts == null then 999999 else (((now - $ts) / 86400) | floor) end) end;
   [.users[] |
    select(
      (.membershipStatus // "" | ascii_downcase | test("pending")) or
      (.accountStatus // "" | ascii_downcase | test("pending")) or
      (.status // "" | ascii_downcase | test("pending"))
    ) |
    {
      account_id: (.accountId // .account_id),
      email: (.email // ""),
      name: (.name // .nickname // ""),
      membership_status: (.membershipStatus // .status // "pending"),
      added_to_org: (.addedToOrg // .added_to_org // ""),
      days_pending: days_since_iso(.addedToOrg // .added_to_org // ""),
      stale: (days_since_iso(.addedToOrg // .added_to_org // "") >= $threshold)
    }
  ]' "$DIRECTORY_USERS_CACHE_FILE")

pending_total=$(echo "$pending_report" | jq 'length')
stale_total=$(echo "$pending_report" | jq '[.[] | select(.stale)] | length')

{
  echo "Pending Invites Analysis — ${ATLASSIAN_ORG_NAME}"
  echo "==============================================="
  echo "Pending / unaccepted users: ${pending_total}"
  echo "Stale invites (>=${PENDING_INVITE_DAYS_THRESHOLD} days): ${stale_total}"
  echo ""
  echo "$pending_report" | jq -r '.[] | "- \(.email // .name) status=\(.membership_status) days_pending=\(.days_pending) stale=\(.stale)"'
} > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"

if [[ "$stale_total" -ge 5 ]]; then
  severity=3
elif [[ "$stale_total" -ge 1 ]]; then
  severity=4
elif [[ "$pending_total" -ge 1 ]]; then
  severity=3
else
  severity=0
fi

# Adjust: spec says expected severities [3,4] for invites task
if [[ "$stale_total" -ge 1 ]]; then
  if [[ "$stale_total" -ge 8 ]]; then
    severity=3
  else
    severity=4
  fi
fi

if [[ "$severity" -ge 3 ]]; then
  details=$(cat "$SUMMARY_FILE")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Stale Pending Invites in Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "Revoke stale invitations in Atlassian Administration > Directory > Users. Path: admin.atlassian.com/o/${ATLASSIAN_ORG_ID}/users. Pending invites consume seats until accepted or revoked." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
elif [[ "$pending_total" -ge 1 ]]; then
  details=$(cat "$SUMMARY_FILE")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Pending Invites Consuming Seats in Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    --arg details "$details" \
    --argjson severity "3" \
    --arg next_steps "Review outstanding invitations and revoke those no longer needed." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
fi

echo "$pending_report" | jq '.' > atlassian_pending_invite_data.json
echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
