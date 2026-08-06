#!/usr/bin/env bash
set -euo pipefail
set -x

# Checks backupEnabled signals on dedicated clusters and gracefully skips tiers where
# cloud backup schedule APIs return 404. Writes JSON issues to atlas_backup_issues.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"
OUTPUT_FILE="${OUTPUT_FILE:-atlas_backup_issues.json}"

issues_json='[]'
notes=()

if ! atlas_resolve_credentials; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Authenticate to MongoDB Atlas API for Project \`${ATLAS_PROJECT_ID}\`" \
    --arg details "Missing or unparsable Atlas API credentials." \
    --arg severity "4" \
    --arg next_steps "Configure atlas_api_key_credentials or ATLAS_PUBLIC_API_KEY / ATLAS_PRIVATE_API_KEY." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

atlas_get "groups/${ATLAS_PROJECT_ID}/clusters?itemsPerPage=500&includeCount=true"
if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
  err="$(echo "$ATLAS_LAST_BODY" | jq -r '.detail // .reason // empty' 2>/dev/null || echo "HTTP $ATLAS_LAST_HTTP_CODE")"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Atlas Clusters API Error for Project \`${ATLAS_PROJECT_ID}\`" \
    --arg details "GET clusters failed: ${err}" \
    --arg severity "4" \
    --arg next_steps "Verify project ID and API role; Flex/serverless layouts may need alternate list endpoints." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

clusters_body="$ATLAS_LAST_BODY"

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  name="$(echo "$row" | jq -r '.name')"
  if ! cluster_matches_filter "$name"; then
    continue
  fi
  ctype="$(echo "$row" | jq -r '.clusterType // ""')"
  backup_on="$(echo "$row" | jq -r '(.backupEnabled // false) or (.providerBackupEnabled // false)')"
  srv="$(echo "$row" | jq -r '.connectionStrings.standardSrv // empty')"

  # Try schedule endpoint for extra signal; 404 is expected on unsupported tiers.
  atlas_get "groups/${ATLAS_PROJECT_ID}/clusters/$(printf '%s' "$name" | jq -sRr @uri)/backup/schedule"
  if [[ "$ATLAS_LAST_HTTP_CODE" == "200" ]]; then
    notes+=("cluster=${name}: backup schedule API available")
  elif [[ "$ATLAS_LAST_HTTP_CODE" == "404" ]]; then
    notes+=("cluster=${name}: cloud backup schedule API not available for this tier; using cluster.backup fields only")
  else
    notes+=("cluster=${name}: backup schedule GET returned HTTP ${ATLAS_LAST_HTTP_CODE} (non-fatal)")
  fi

  # Ignore types that typically do not expose dedicated backup toggles via this view
  if [[ "$ctype" == "REPLICA_SET" || "$ctype" == "SHARDED" || "$ctype" == "GEOSHARDED" ]]; then
    if [[ "$backup_on" != "true" ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Cloud Backup Disabled for Atlas Cluster \`${name}\`" \
        --arg details "clusterType=${ctype}; backupEnabled/providerBackupEnabled=false; standardSrv=${srv:-n/a}" \
        --arg severity "4" \
        --arg next_steps "Enable cloud backup / point-in-time recovery for production clusters in Atlas UI or API (https://www.mongodb.com/docs/atlas/backup/)." \
        '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
    fi
  else
    notes+=("cluster=${name}: clusterType=${ctype} — backup check skipped (non dedicated layout)")
  fi
done < <(echo "$clusters_body" | jq -c '.results // [] | .[]')

printf '%s\n' "${notes[@]:-}"

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
