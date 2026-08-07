#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Apigee API Proxies and Deployments
#
# Lists all API proxies, environments, and the deployment state (current
# revision, revision state, status) of every proxy revision across environments
# in the Apigee organization. Serves as the discovery/input for the downstream
# check tasks.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG          - Apigee organization name
#   GCP_PROJECT_ID      - GCP project hosting the Apigee runtime (used for auth)
#
# OUTPUTS:
#   proxy_discovery.json        - Enriched dump of proxies, deployments, and envs
#   proxy_discovery_issues.json - JSON array of issues (usually empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="proxy_discovery_issues.json"
CONFIG_FILE="proxy_discovery.json"
issues_json='[]'

APIGEE_BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

echo "Discovering Apigee proxies and deployments in organization: $APIGEE_ORG"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee Admin API for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee API proxies and deployments should be retrievable" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the service account (gcp_credentials) has roles/apigee.readOnlyAdmin and roles/monitoring.viewer on project $GCP_PROJECT_ID." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "{}" > "$CONFIG_FILE"
    echo "Authentication failed. Issues written to $ISSUES_FILE"
    exit 0
fi

api_get() {
    curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/json" "$@"
}

# --- Enumerate API proxies ---
proxies_json=$(api_get "$APIGEE_BASE/apiproxies" 2>err.log || true)
if ! echo "$proxies_json" | jq -e . >/dev/null 2>&1; then
    err_msg=$(cat err.log 2>/dev/null || echo "$proxies_json")
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot access API proxies for org \`$APIGEE_ORG\`" \
        --arg details "Apigee Admin API GET /apiproxies failed: $err_msg" \
        --arg severity "4" \
        --arg expected "The list of API proxies should be retrievable" \
        --arg actual "Listing API proxies failed" \
        --arg next_steps "Verify the service account has apigee.apiproxyrevisions.read permission and the Apigee API is enabled." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "{}" > "$CONFIG_FILE"
    echo "Proxy discovery failed. Issues written to $ISSUES_FILE"
    exit 0
fi

proxy_names=$(echo "$proxies_json" | jq -r '.proxies[]?.name // empty' 2>/dev/null || true)

# --- Enumerate environments ---
envs_json=$(api_get "$APIGEE_BASE/environments" 2>/dev/null || echo "{}")
env_names=$(echo "$envs_json" | jq -r '.environments[]? // empty' 2>/dev/null || true)

proxy_objects='[]'
while IFS= read -r proxy; do
    [ -z "$proxy" ] && continue
    proxy_detail=$(api_get "$APIGEE_BASE/apiproxies/$proxy" 2>/dev/null || echo "{}")
    meta=$(echo "$proxy_detail" | jq -c --arg p "$proxy" '{name:$p,latestRevisionId:(.latestRevisionId // ""),revisions:(if (.revision|type)=="array" then .revision else [] end)}' 2>/dev/null || echo "{}")
    dep_json=$(api_get "$APIGEE_BASE/apiproxies/$proxy/deployments" 2>/dev/null || echo "{}")
    dep_list=$(echo "$dep_json" | jq -c '[.deployments[]? | {environment:(.environment // ""),revision:(.revision // ""),state:(.state // "")}]' 2>/dev/null || echo "[]")
    entry=$(jq -nc --argjson detail "$meta" --argjson dep "$dep_list" '{details:$detail, deployments:$dep}')
    proxy_objects=$(echo "$proxy_objects" | jq -c --argjson e "$entry" '. += [$e]')
done <<< "$proxy_names"

env_objects='[]'
while IFS= read -r env; do
    [ -z "$env" ] && continue
    env_deployments=$(api_get "$APIGEE_BASE/environments/$env/deployments" 2>/dev/null || echo "{}")
    dep_list=$(echo "$env_deployments" | jq -c '[.deployments[]? | {apiProxy:(.apiProxy // ""),revision:(.revision // ""),state:(.state // "")}]' 2>/dev/null || echo "[]")
    entry=$(jq -nc --arg name "$env" --argjson deployments "$dep_list" '{name:$name, deployments:$deployments}')
    env_objects=$(echo "$env_objects" | jq -c --argjson e "$entry" '. += [$e]')
done <<< "$env_names"

jq -n \
    --arg org "$APIGEE_ORG" \
    --argjson proxies "$proxy_objects" \
    --argjson environments "$env_objects" \
    '{organization:$org, proxies:$proxies, environments:$environments}' > "$CONFIG_FILE"

pcount=$(echo "$proxy_objects" | jq 'length')
ecount=$(echo "$env_objects" | jq 'length')
echo "Discovered $pcount API proxy(ies) and $ecount environment(s) in org $APIGEE_ORG."
echo "API proxies:"
echo "$proxy_names" | sed 's/^/  /'
echo "Environments:"
echo "$env_names" | sed 's/^/  /'

echo "$issues_json" > "$ISSUES_FILE"
echo "Discovery dump written to $CONFIG_FILE"
