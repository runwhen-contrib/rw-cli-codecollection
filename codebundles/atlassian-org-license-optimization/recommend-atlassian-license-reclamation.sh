#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   ATLASSIAN_ORG_ID
#   ATLASSIAN_ORG_NAME
#
# OPTIONAL:
#   RECLAMATION_MIN_SEATS (default 5)
#   INACTIVE_DAYS_THRESHOLD, PENDING_INVITE_DAYS_THRESHOLD, MIN_OVERLAP_PRODUCTS
# -----------------------------------------------------------------------------

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"
: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"
: "${RECLAMATION_MIN_SEATS:=5}"
: "${INACTIVE_DAYS_THRESHOLD:=90}"
: "${PENDING_INVITE_DAYS_THRESHOLD:=30}"
: "${MIN_OVERLAP_PRODUCTS:=2}"
: "${PRODUCTS:=All}"

OUTPUT_FILE="atlassian_reclamation_issues.json"
REPORT_FILE="atlassian_license_reclamation_report.md"
issues_json='[]'

source "$(dirname "$0")/atlassian-api-helpers.sh"

echo "Synthesizing license reclamation recommendations for: ${ATLASSIAN_ORG_NAME}"

# Run upstream analyzers if their outputs are absent.
if [[ ! -f atlassian_inactive_billable_issues.json ]]; then
  ./identify-atlassian-inactive-billable-users.sh || true
fi
if [[ ! -f atlassian_product_overlap_issues.json ]]; then
  ./analyze-atlassian-product-overlap.sh || true
fi
if [[ ! -f atlassian_pending_invite_issues.json ]]; then
  ./surface-atlassian-pending-invites.sh || true
fi

read_array() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo '[]'
  fi
}

inactive_issues=$(read_array atlassian_inactive_billable_issues.json)
overlap_issues=$(read_array atlassian_product_overlap_issues.json)
invite_issues=$(read_array atlassian_pending_invite_issues.json)

inactive_count=$(jq '[.[] | select(.severity >= 2)] | length' <<< "$inactive_issues")
overlap_count=$(jq '[.[] | select(.severity >= 2)] | length' <<< "$overlap_issues")
invite_count=$(jq '[.[] | select(.severity >= 3)] | length' <<< "$invite_issues")

inactive_seats=0
if [[ -f atlassian_inactive_billable_data.json ]]; then
  inactive_seats=$(jq 'length' atlassian_inactive_billable_data.json)
fi
overlap_seats=0
if [[ -f atlassian_product_overlap_data.json ]]; then
  overlap_seats=$(jq '[.[].redundant[]] | length' atlassian_product_overlap_data.json)
fi
stale_invites=0
if [[ -f atlassian_pending_invite_data.json ]]; then
  stale_invites=$(jq '[.[] | select(.stale)] | length' atlassian_pending_invite_data.json)
fi

{
  echo "# Atlassian License Reclamation Report"
  echo ""
  echo "**Organization:** ${ATLASSIAN_ORG_NAME} (\`${ATLASSIAN_ORG_ID}\`)"
  echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "## Executive Summary"
  echo ""
  echo "| Category | Reclaimable signal | Estimated seats |"
  echo "|----------|-------------------|-----------------|"
  echo "| Inactive billable users (>${INACTIVE_DAYS_THRESHOLD}d) | ${inactive_count} issue(s) | ${inactive_seats} |"
  echo "| Redundant product access | ${overlap_count} issue(s) | ${overlap_seats} |"
  echo "| Stale pending invites (>=${PENDING_INVITE_DAYS_THRESHOLD}d) | ${invite_count} issue(s) | ${stale_invites} |"
  echo ""
  echo "## Prioritized Recommendations"
  echo ""
  echo "1. **Suspend before remove** — suspend inactive users first to stop billing while preserving group memberships for easy restore."
  echo "2. **Revoke stale invites** — pending invitations consume tier capacity until revoked in Atlassian Administration."
  echo "3. **Consolidate product access** — remove redundant product licenses for users active on a subset of products."
  echo "4. **Teamwork Collection note** — duplicate product rows may not imply duplicate billing; confirm licensing model before bulk removal."
  echo ""
  echo "## Administration Paths"
  echo ""
  echo "- Managed accounts: https://admin.atlassian.com/o/${ATLASSIAN_ORG_ID}/users"
  echo "- Suspend (directory API, operator action): POST /v2/orgs/{orgId}/directories/{directoryId}/users/{accountId}/suspend"
  echo "- Remove from directory (operator action): DELETE /v2/orgs/{orgId}/directories/{directoryId}/users/{accountId}"
  echo ""
  echo "## Findings Detail"
  echo ""
  echo "### Inactive Billable Users"
  if [[ -f atlassian_inactive_billable_summary.txt ]]; then
    sed 's/^/    /' atlassian_inactive_billable_summary.txt
  else
    echo "    (no data)"
  fi
  echo ""
  echo "### Product Overlap"
  if [[ -f atlassian_product_overlap_summary.txt ]]; then
    sed 's/^/    /' atlassian_product_overlap_summary.txt
  else
    echo "    (no data)"
  fi
  echo ""
  echo "### Pending Invites"
  if [[ -f atlassian_pending_invite_summary.txt ]]; then
    sed 's/^/    /' atlassian_pending_invite_summary.txt
  else
    echo "    (no data)"
  fi
} > "$REPORT_FILE"

cat "$REPORT_FILE"

total_reclaimable=$(( inactive_seats + overlap_seats + stale_invites ))
recommendations='[]'

if [[ "$inactive_seats" -ge "$RECLAMATION_MIN_SEATS" ]]; then
  recommendations=$(echo "$recommendations" | jq \
    --argjson seats "$inactive_seats" \
    --arg threshold "$INACTIVE_DAYS_THRESHOLD" \
    '. += [{
      action: "suspend_inactive_billable",
      priority: 1,
      estimated_seats: $seats,
      severity: 3,
      title: "Suspend inactive billable users",
      next_steps: ("Suspend \($seats) billable users inactive >" + $threshold + " days via Atlassian Administration > Directory.")
    }]')
fi

if [[ "$overlap_seats" -ge "$RECLAMATION_MIN_SEATS" ]]; then
  recommendations=$(echo "$recommendations" | jq \
    --argjson seats "$overlap_seats" \
    '. += [{
      action: "consolidate_product_access",
      priority: 2,
      estimated_seats: $seats,
      severity: 3,
      title: "Consolidate redundant product access",
      next_steps: ("Revoke redundant product licenses for users active on fewer than " + ($seats | tostring) + " assigned products.")
    }]')
fi

if [[ "$stale_invites" -ge 1 ]]; then
  sev=4
  [[ "$stale_invites" -ge "$RECLAMATION_MIN_SEATS" ]] && sev=3
  recommendations=$(echo "$recommendations" | jq \
    --argjson seats "$stale_invites" \
    --argjson severity "$sev" \
    '. += [{
      action: "revoke_stale_invites",
      priority: 3,
      estimated_seats: $seats,
      severity: $severity,
      title: "Revoke stale pending invitations",
      next_steps: ("Revoke \($seats) stale pending invites in Atlassian Administration > Directory > Users.")
    }]')
fi

if [[ "$(echo "$recommendations" | jq 'length')" -eq 0 && "$total_reclaimable" -eq 0 ]]; then
  echo "No reclamation candidates meeting thresholds. Organization appears efficiently utilized."
  echo '[]' > "$OUTPUT_FILE"
  exit 0
fi

report_details=$(cat "$REPORT_FILE")
while IFS= read -r rec; do
  title=$(echo "$rec" | jq -r '.title')
  severity=$(echo "$rec" | jq -r '.severity')
  next_steps=$(echo "$rec" | jq -r '.next_steps')
  seats=$(echo "$rec" | jq -r '.estimated_seats')
  action=$(echo "$rec" | jq -r '.action')
  details="Action: ${action}\nEstimated reclaimable seats: ${seats}\n\n${report_details}"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "${title} for Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
done < <(echo "$recommendations" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_FILE"
echo "Reclamation report saved to ${REPORT_FILE}"
echo "Issues saved to ${OUTPUT_FILE}"
