#!/usr/bin/env bash
set -euo pipefail
set -x

# Audits project IP access list for overly permissive CIDRs and empty lists when
# clusters advertise public SRV connection strings. Writes atlas_network_issues.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"
OUTPUT_FILE="${OUTPUT_FILE:-atlas_network_issues.json}"

issues_json='[]'

if ! atlas_resolve_credentials; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Authenticate to MongoDB Atlas API for Project \`${ATLAS_PROJECT_ID}\`" \
    --arg details "Missing or unparsable Atlas API credentials." \
    --arg severity "4" \
    --arg next_steps "Configure atlas_api_key_credentials or API key env vars." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

atlas_get "groups/${ATLAS_PROJECT_ID}/accessList?itemsPerPage=500"
if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
  err="$(echo "$ATLAS_LAST_BODY" | jq -r '.detail // .reason // empty' 2>/dev/null || echo "HTTP $ATLAS_LAST_HTTP_CODE")"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Atlas Project IP Access List API Error for \`${ATLAS_PROJECT_ID}\`" \
    --arg details "GET accessList failed: ${err}" \
    --arg severity "3" \
    --arg next_steps "Confirm Atlas Admin API access; some organizations restrict IP access list reads." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

entries="$(echo "$ATLAS_LAST_BODY" | jq -c '.results // []')"
count="$(echo "$entries" | jq 'length')"
echo "Project IP access list entries: $count"

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  cidr="$(echo "$row" | jq -r '.cidrBlock // empty')"
  ip="$(echo "$row" | jq -r '.ipAddress // empty')"
  comment="$(echo "$row" | jq -r '.comment // ""')"
  target="${cidr:-$ip}"
  if [[ "$target" == "0.0.0.0/0" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Overly Permissive Atlas Network Entry \`${target}\`" \
      --arg details "comment=${comment:-none}; full_entry=$(echo "$row" | jq -c .)" \
      --arg severity "3" \
      --arg next_steps "Replace open CIDR 0.0.0.0/0 with narrow corporate egress IPs or move workloads to private networking / VPC peering." \
      '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  fi
  if [[ "$cidr" =~ ^0\.0\.0\.0/[0-9]{1,2}$ ]] && [[ "$cidr" != "0.0.0.0/0" ]]; then
    wide="${cidr##*/}"
    if [[ "$wide" -le 8 ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Broad Atlas Network CIDR \`${cidr}\`" \
        --arg details "comment=${comment:-none}" \
        --arg severity "2" \
        --arg next_steps "Tighten CIDR to minimum required ranges; document temporary exceptions in Atlas entry comments with owners and expiry." \
        '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
    fi
  fi
done < <(echo "$entries" | jq -c '.[]')

atlas_get "groups/${ATLAS_PROJECT_ID}/clusters?itemsPerPage=500"
clusters_body="$ATLAS_LAST_BODY"
has_public_srv=0
if [[ "$ATLAS_LAST_HTTP_CODE" == "200" ]]; then
  while IFS= read -r row; do
    name="$(echo "$row" | jq -r '.name')"
    cluster_matches_filter "$name" || continue
    srv="$(echo "$row" | jq -r '.connectionStrings.standardSrv // empty')"
    if [[ -n "$srv" ]]; then
      has_public_srv=1
    fi
  done < <(echo "$clusters_body" | jq -c '.results // [] | .[]')
else
  echo "Clusters fetch for network correlation failed (HTTP ${ATLAS_LAST_HTTP_CODE}); skipping empty-list heuristic."
fi

if [[ "$count" -eq 0 && "$has_public_srv" -eq 1 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Empty Atlas IP Access List with Public Cluster SRV Endpoints" \
    --arg details "No project IP allowlist entries but at least one in-scope cluster exposes connectionStrings.standardSrv." \
    --arg severity "2" \
    --arg next_steps "Confirm whether traffic is locked via Private Endpoint / peering only. If clusters are internet-reachable, add least-privilege CIDRs; otherwise document the private-only architecture." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
