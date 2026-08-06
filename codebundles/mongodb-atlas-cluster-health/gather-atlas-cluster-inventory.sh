#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/atlas-api-common.inc.sh"

OUTPUT_FILE="atlas_cluster_inventory_issues.json"
: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"

ATLAS_ORG_ID="${ATLAS_ORG_ID:-}"
CLUSTER_FILTER="${CLUSTER_FILTER:-}"

issues_json='[]'

if ! atlas_resolve_credentials; then
  issues_json="$(append_issue_json "$issues_json" \
    "Cannot authenticate to MongoDB Atlas API for inventory" \
    "Missing ATLAS_PUBLIC_API_KEY / ATLAS_PRIVATE_API_KEY or parsable atlas_api_key_credentials JSON." \
    4 \
    "Create an Atlas programmatic API key with Project Read Only and map it via the atlas_api_key_credentials secret (JSON keys ATLAS_PUBLIC_API_KEY and ATLAS_PRIVATE_API_KEY).")"
  echo "$issues_json" >"$OUTPUT_FILE"
  printf '%s\n' "Atlas credential resolution failed." >&2
  exit 0
fi

atlas_clusters_json "${ATLAS_PROJECT_ID}"
hc="${atlas_last_http_status:-}"
body="${atlas_last_http_body:-}"

if [[ "$hc" != "200" ]]; then
  details="HTTP ${hc} listing clusters — $(echo "$body" | jq -c .detail,.error,.errorCode? 2>/dev/null || echo "$body")"
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas cluster inventory request failed for project \`${ATLAS_PROJECT_ID}\`" \
    "$details" \
    4 \
    "Confirm ATLAS_PROJECT_ID, API key scopes, Accept header (${ATLAS_ACCEPT_HEADER}), and project membership.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  printf '%s\n' "$details"
  exit 0
fi

filtered="$(filter_clusters_by_name "$body" "$CLUSTER_FILTER")"
count_filtered="$(echo "$filtered" | jq 'length')"
if [[ "$count_filtered" == "0" ]]; then
  issues_json="$(append_issue_json "$issues_json" \
    "No Atlas clusters matched filter for project \`${ATLAS_PROJECT_ID}\`" \
    "CLUSTER_FILTER is set (${CLUSTER_FILTER}) but no clusters in this project matched the names supplied." \
    2 \
    "Unset CLUSTER_FILTER to evaluate all clusters, or fix comma-separated names to match Atlas cluster names exactly.")"
fi

audit_ctx=""
[[ -n "$ATLAS_ORG_ID" ]] && audit_ctx="$(printf ' ATLAS_ORG_ID=%s' "$ATLAS_ORG_ID")"

printf '📋 MongoDB Atlas project %s%s — %s cluster(s) after filter\n' \
  "${ATLAS_PROJECT_ID}" "${audit_ctx}" "${count_filtered}"

declare -i idx=0
while IFS= read -r cjson; do
  [[ -z "$cjson" ]] && continue
  idx+=1
  name="$(echo "$cjson" | jq -r '.name // "-"')"
  st="$(echo "$cjson" | jq -r '.stateName // (.state.name // "-")')"
  ver="$(echo "$cjson" | jq -r '.mongoDBMajorVersion // .mongoDBVersion // "-"')"
  paused="$(echo "$cjson" | jq -r '.paused // false')"
  ctype="$(echo "$cjson" | jq -r '.clusterType // "-"')"
  prov="$(echo "$cjson" | jq -r '.providerSettings.providerName // "-"')"
  reg="$(echo "$cjson" | jq -r '.providerSettings.regionName // "-"')"
  size="$(echo "$cjson" | jq -r '.providerSettings.instanceSizeName // "-"')"
  disk="$(echo "$cjson" | jq -r '.diskSizeGB // "-"')"

  printf '  [%s] %s | type=%s state=%s version=%s provider=%s region=%s tier=%s diskGB=%s paused=%s\n' \
    "$idx" "$name" "$ctype" "$st" "$ver" "$prov" "$reg" "$size" "$disk" "$paused"

  # inventory issues: paused / noteworthy states (severity 1–2)
  if [[ "$paused" == "true" ]]; then
    issues_json="$(append_issue_json "$issues_json" \
      "Cluster \`${name}\` is paused" \
      "Atlas reports paused=true for cluster \`${name}\` (${prov}/${reg}, ${size}). Operational traffic is halted until resumed." \
      2 \
      "Resume via Atlas UI/API if maintenance is complete, or acknowledge intentional pause outside production windows.")"
  fi
  if [[ "$st" != "IDLE" && "$st" != "-" && "$paused" != "true" ]]; then
    issues_json="$(append_issue_json "$issues_json" \
      "Cluster \`${name}\` is not in IDLE state (${st})" \
      "stateName=${st} for \`${name}\` — Atlas may still be applying changes." \
      1 \
      "Track Atlas UI Deployment view; informational while updates finish unless coupled with outage symptoms.")"
  fi
done < <(echo "$filtered" | jq -c '.[]')

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
printf 'Inventory complete. Issues written to %s\n' "$OUTPUT_FILE"
