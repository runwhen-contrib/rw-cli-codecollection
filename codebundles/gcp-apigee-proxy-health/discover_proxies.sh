#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# discover_proxies.sh
# Lists all Apigee API proxies and their deployments using the org-wide
# /organizations/{org}/deployments endpoint plus /apis?includeRevisions=true,
# then enriches each deployment with its runtime status. Records, per
# proxy/environment, the deployed revision, revision state and any errors[] so
# downstream tasks can evaluate without repeating the discovery calls.
#
# Call budget: 1 (org resolution) + 1 (deployments) + 1 (proxies w/ revisions)
# + one runtime-status call per deployment. `state` and `errors[]` are NOT
# returned by any deployment LIST endpoint -- the discovery document marks both
# "displayed only when viewing deployment status" -- so the per-deployment
# status call is the only way to obtain them.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#   PROXIES            - optional; comma-separated proxy filter ("All" = all)
#   ENVIRONMENTS       - optional; comma-separated env filter ("All" = all)
#   APIGEE_MAX_STATUS_CALLS - cap on runtime-status calls (default 250)
#
# OUTPUTS:
#   apigee_deployments.json  - filtered deployments array, enriched with status
#   apigee_proxies.json      - filtered proxy objects (name, revision[], latest)
#   apigee_discovery_issues.json - issues (auth/org resolution failures)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
PROXIES="${PROXIES:-All}"
ENVIRONMENTS="${ENVIRONMENTS:-All}"

. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="apigee_discovery_issues.json"
apigee_init_issues "$ISSUES_FILE"
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
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
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
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
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

# ONE org-wide deployments call and ONE proxies call. Since this is the
# discovery task, always fetch fresh so the cache reflects current state.
deployments_json=$(apigee_list_deployments "$ORG")
proxies_json=$(apigee_list_proxy_objects "$ORG")

# Apply PROXIES filter to deployments (by apiProxy name) and environments.
# Filter BEFORE enrichment so the status-call budget is spent only on
# deployments this run actually evaluates.
if [ "$proxy_filter" != "All" ]; then
    proxies_json=$(echo "$proxies_json" | jq -c --arg f "$proxy_filter" 'map(select(.name as $n | ( $f | split(",") ) | index($n)))')
    deployments_json=$(echo "$deployments_json" | jq -c --arg f "$proxy_filter" 'map(select(.apiProxy as $p | ( $f | split(",") ) | index($p)))')
fi
if [ "$env_filter" != "All" ]; then
    deployments_json=$(echo "$deployments_json" | jq -c --arg f "$env_filter" 'map(select(.environment as $e | ( $f | split(",") ) | index($e)))')
fi

raw_count=$(echo "$deployments_json" | jq length)
if [ "$raw_count" -gt "$APIGEE_MAX_STATUS_CALLS" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Apigee deployment status only partially retrieved in org \`$ORG\`" \
        --arg details "This org has $raw_count deployment(s) in scope but APIGEE_MAX_STATUS_CALLS is $APIGEE_MAX_STATUS_CALLS. Deployments beyond that cap are recorded with state UNKNOWN and are NOT evaluated for deployment health." \
        --arg severity "3" \
        --arg expected "Runtime status should be retrieved for every in-scope deployment" \
        --arg actual "Status retrieved for $APIGEE_MAX_STATUS_CALLS of $raw_count deployment(s)" \
        --arg next_steps "Raise APIGEE_MAX_STATUS_CALLS, or narrow PROXIES / ENVIRONMENTS so every in-scope deployment is evaluated." \
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
fi

echo "Retrieving runtime status for $raw_count deployment(s) (cap: $APIGEE_MAX_STATUS_CALLS)..."
deployments_json=$(apigee_enrich_deployments "$ORG" "$deployments_json")

echo "$deployments_json" > "$DEPLOYMENTS_FILE"
echo "$proxies_json" > "$PROXIES_FILE"

proxy_count=$(echo "$proxies_json" | jq length)
deploy_count=$(echo "$deployments_json" | jq length)
unknown_count=$(echo "$deployments_json" | jq '[.[] | select(.statusUnavailable == true)] | length')
echo "Discovered $proxy_count proxy(ies) with $deploy_count deployment(s)."

if [ "$unknown_count" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Runtime status unavailable for $unknown_count Apigee deployment(s) in org \`$ORG\`" \
        --arg details "$unknown_count of $deploy_count deployment(s) returned no runtime state from the deployment status view. Their deployment health is unknown, not healthy." \
        --arg severity "3" \
        --arg expected "The deployment status view should report a runtime state for every deployment" \
        --arg actual "$unknown_count deployment(s) have state UNKNOWN" \
        --arg next_steps "Confirm the service account holds roles/apigee.readOnlyAdmin and that the Apigee runtime instances are reachable, then re-run discovery." \
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
fi

echo ""
echo "--- Proxy summary (name / revisions / latest) ---"
echo "$proxies_json" | jq -r '.[] | "\(.name) / \((.revision // []) | length) revision(s) / latest \(.latestRevisionId // "unknown")"'
echo ""
echo "--- Deployment summary (proxy / env / revision / state) ---"
echo "$deployments_json" | jq -r '.[] | "\(.apiProxy) / \(.environment) / rev \(.revision) / \(.state // "N/A")"'

echo "$issues_json" > "$ISSUES_FILE"
echo "Discovery complete. Found $(jq length "$ISSUES_FILE") issue(s)."
