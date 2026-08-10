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
apigee_reset_api_errors
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
    echo "[]" > "$DEPLOYMENTS_FILE"
    echo "[]" > "$PROXIES_FILE"

    # Two very different situations produce an empty org list, and collapsing
    # them is what made this bundle both cry wolf and miss real outages:
    #
    #   the lookup FAILED       -> we know nothing. Must not score healthy.
    #   the lookup SUCCEEDED    -> we know there is no Apigee here. There is
    #     and returned nothing      nothing to be unhealthy about, so this is
    #                               not an incident; it means the SLX is
    #                               scoped to a project that does not use
    #                               Apigee. Report it as housekeeping (sev 4).
    #
    # This is only safe to distinguish because apigee_curl records HTTP status.
    if [ "$(apigee_api_error_count)" -gt 0 ]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Cannot reach the Apigee API for project \`$GCP_PROJECT_ID\`" \
            --arg details "The Apigee organization lookup for project '$GCP_PROJECT_ID' failed: $(apigee_api_error_summary). Whether this project has a healthy Apigee organization is unknown." \
            --arg severity "2" \
            --arg expected "The Apigee organization lookup should return 2xx" \
            --arg actual "Organization lookup failed: $(apigee_api_error_summary)" \
            --arg next_steps "Confirm the Apigee API is enabled for this project and the service account holds roles/apigee.readOnlyAdmin. Set APIGEE_ORG explicitly if the org belongs to a different project." \
            '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
    else
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Apigee organization is linked to project \`$GCP_PROJECT_ID\`" \
            --arg details "The Apigee organization list was retrieved successfully and contains no organization for project '$GCP_PROJECT_ID'. This project does not use Apigee, so there is no proxy health to report -- this is a scoping observation, not an outage." \
            --arg severity "4" \
            --arg expected "This SLX should be scoped to projects that host an Apigee organization" \
            --arg actual "Project '$GCP_PROJECT_ID' has no Apigee organization" \
            --arg next_steps "Remove this SLX from '$GCP_PROJECT_ID', or narrow the generation rule to projects that use Apigee. If the org lives in a different project, set APIGEE_ORG explicitly." \
            '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
        echo "No Apigee organization for project '$GCP_PROJECT_ID'; nothing to evaluate."
    fi
    echo "$issues_json" > "$ISSUES_FILE"
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

# An inventory call that failed yields [] after `// []`, which is
# indistinguishable from a genuinely empty org unless the status is checked.
api_errors=$(apigee_api_error_count)
if [ "$api_errors" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Apigee Management API calls failed for project \`$GCP_PROJECT_ID\`" \
        --arg details "$api_errors Apigee API call(s) returned a non-2xx status: $(apigee_api_error_summary). The proxy and deployment inventory below is incomplete, so no conclusion about Apigee health can be drawn from this run." \
        --arg severity "2" \
        --arg expected "Every Apigee Management API call should return 2xx" \
        --arg actual "$api_errors call(s) failed: $(apigee_api_error_summary)" \
        --arg next_steps "Confirm the Apigee API is enabled for this project, that the Apigee organization exists and is reachable, and that the service account holds roles/apigee.readOnlyAdmin (plus roles/apigee.analyticsViewer for stats). 403 usually means a disabled API or missing IAM; 404 a wrong APIGEE_ORG; 429 quota exhaustion." \
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
    echo "WARNING: $api_errors Apigee API call(s) failed ($(apigee_api_error_summary)); inventory is incomplete."
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
