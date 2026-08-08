#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# discover_proxies.sh
# Lists all Apigee API proxies and their deployments using the org-wide
# /organizations/{org}/deployments endpoint (ONE call) plus /apis, respecting
# management API rate limits. Records, per proxy/environment, the deployed
# revision, revision state and any errors[] so downstream tasks can evaluate
# without per-proxy looping.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#   PROXIES            - optional; comma-separated proxy filter ("All" = all)
#   ENVIRONMENTS       - optional; comma-separated env filter ("All" = all)
#
# OUTPUTS:
#   apigee_deployments.json  - filtered deployments array
#   apigee_proxies.json      - filtered proxy list
#   apigee_discovery_issues.json - issues (auth/org resolution failures)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
PROXIES="${PROXIES:-All}"
ENVIRONMENTS="${ENVIRONMENTS:-All}"

. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="apigee_discovery_issues.json"
issues_json='[]'

echo "Discovering Apigee proxies and deployments for project: $GCP_PROJECT_ID"

if [ -z "$(apigee_access_token)" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Management API." \
        --arg severity "3" \
        --arg expected "Apigee management API should be reachable with the service account" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the GCP service account is authenticated and has roles/apigee.readOnlyAdmin (plus roles/apigee.analyticsViewer for stats)." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$DEPLOYMENTS_FILE"
    echo "[]" > "$PROXIES_FILE"
    exit 0
fi

ORG=$(apigee_org)
if [ -z "$ORG" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot resolve Apigee organization for project \`$GCP_PROJECT_ID\`" \
        --arg details "No Apigee organization maps to GCP project '$GCP_PROJECT_ID'. Set APIGEE_ORG explicitly if the project has an Apigee org tied to a different project." \
        --arg severity "3" \
        --arg expected "One or more Apigee organizations should be linked to this GCP project" \
        --arg actual "No organization found for project '$GCP_PROJECT_ID'" \
        --arg next_steps "Verify the Apigee org exists and is linked to this GCP project; set APIGEE_ORG if needed." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$DEPLOYMENTS_FILE"
    echo "[]" > "$PROXIES_FILE"
    exit 0
fi

echo "Using Apigee organization: $ORG"
export APIGEE_ORG="$ORG"

# Build proxy filter (jq expression array). "All" -> no filter.
proxy_filter="$(apigee_expand_csv "$PROXIES")"
env_filter="$(apigee_expand_csv "$ENVIRONMENTS")"

# ONE org-wide deployments call. Since this is the discovery task, always fetch
# fresh so the cache reflects current state.
token=$(apigee_access_token)
deployments_json=$(curl -s -H "Authorization: Bearer $token" "${APIGEE_BASE}/organizations/${ORG}/deployments" | jq -c '.deployments // []' || echo "[]")
proxies_json=$(curl -s -H "Authorization: Bearer $token" "${APIGEE_BASE}/organizations/${ORG}/apis?includeRevisions=false" | jq -c '[.proxies // [] | .[].name]' || echo "[]")

# Apply PROXIES filter to deployments (by apiProxy name) and environments.
if [ "$proxy_filter" != "All" ]; then
    proxies_json=$(echo "$proxies_json" | jq -c --arg f "$proxy_filter" 'map(select(( $f | split(",") ) | index(.)))')
    deployments_json=$(echo "$deployments_json" | jq -c --arg f "$proxy_filter" 'map(select(.apiProxy as $p | ( $f | split(",") ) | index($p)))')
fi
if [ "$env_filter" != "All" ]; then
    deployments_json=$(echo "$deployments_json" | jq -c --arg f "$env_filter" 'map(select(.environment as $e | ( $f | split(",") ) | index($e)))')
fi

echo "$deployments_json" > "$DEPLOYMENTS_FILE"
echo "$proxies_json" > "$PROXIES_FILE"

proxy_count=$(echo "$proxies_json" | jq length)
deploy_count=$(echo "$deployments_json" | jq length)
echo "Discovered $proxy_count proxy(ies) with $deploy_count deployment(s)."
echo ""
echo "--- Proxy summary ---"
echo "$proxies_json" | jq -r '.[]'
echo ""
echo "--- Deployment summary (proxy / env / revision / state) ---"
echo "$deployments_json" | jq -r '.[] | "\(.apiProxy) / \(.environment) / rev \(.revision) / \(.state // "N/A")"'

echo "$issues_json" > "$ISSUES_FILE"
echo "Discovery complete. Found $(jq length "$ISSUES_FILE") issue(s)."
