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

# Start from "in scope, org unresolved". A stale topology from an earlier run in
# the same working directory must never decide this run's applicability.
apigee_write_topology true "" "not_yet_resolved" "failed"

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

# -----------------------------------------------------------------------------
# INTERIM (remove when the generation rule can gate on gcp_apigee_organizations)
#
# The rule matches every indexed project, so this bundle is pointed at projects
# that have never used Apigee. Deciding applicability here is what stops those
# from carrying a permanent issue in the runbook.
#
# The ONLY thing that makes this safe is refusing to collapse two situations:
#
#   positive determination of absence -> we asked and got a definite answer:
#     * 2xx, and no organization for this project, or
#     * 403/404 saying the Apigee API was never enabled (no API, no org)
#     -> applicable=false, and NO issue is raised
#
#   failure to determine -> anything else. Plain permission denial, network
#     failure, unparseable body, any other status. We know nothing.
#     -> issue raised, exactly as before
#
# Never widen the absence branch to bare PERMISSION_DENIED: that turns "cannot
# tell" into "nothing here", which is the healthy-while-blind reporting this
# bundle was fixed to remove.
# -----------------------------------------------------------------------------
if [ -n "${APIGEE_ORG:-}" ]; then
    # The operator named an org, so applicability is not in question and any
    # failure reaching it is a failure, not an absence.
    ORG="${APIGEE_ORG#organizations/}"
else
    apigee_probe "/organizations"
    org_status="$APIGEE_PROBE_STATUS"
    org_body="$APIGEE_PROBE_BODY"
    ORG=""

    case "$org_status" in
        2??)
            ORG=$(printf '%s' "$org_body" | jq -r --arg p "$GCP_PROJECT_ID" '
                (.organizations // [])[]
                | select(.projectId == $p or ((.projectIds // []) | index($p)))
                | .organization' 2>/dev/null | head -n 1)
            if [ -z "$ORG" ]; then
                echo "Apigee organization list retrieved; no organization for project '$GCP_PROJECT_ID'."
                echo "This project does not use Apigee -- nothing to evaluate."
                apigee_write_topology false "" "no_organization_in_project" "not_applicable"
                echo "[]" > "$DEPLOYMENTS_FILE"
                echo "[]" > "$PROXIES_FILE"
                echo "$issues_json" > "$ISSUES_FILE"
                exit 0
            fi
            ;;
        *)
            if apigee_api_disabled "$org_status" "$org_body"; then
                echo "The Apigee API is not enabled on project '$GCP_PROJECT_ID' (HTTP $org_status)."
                echo "No organization can exist without it -- nothing to evaluate."
                apigee_write_topology false "" "apigee_api_not_enabled" "not_applicable"
                echo "[]" > "$DEPLOYMENTS_FILE"
                echo "[]" > "$PROXIES_FILE"
                echo "$issues_json" > "$ISSUES_FILE"
                exit 0
            fi
            # Could not determine. This is a failure, and must stay one.
            api_msg=$(printf '%s' "$org_body" | jq -r 'if type=="object" then (.error.message // "no error message") else "unparseable response body" end' 2>/dev/null || echo "unparseable response body")
            apigee_write_topology true "" "lookup_failed" "failed"
            echo "[]" > "$DEPLOYMENTS_FILE"
            echo "[]" > "$PROXIES_FILE"
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Cannot determine the Apigee organization for project \`$GCP_PROJECT_ID\`" \
                --arg details "The Apigee organization lookup for project '$GCP_PROJECT_ID' returned HTTP $org_status: $api_msg. This is not a determination that Apigee is unused -- whether this project has a healthy Apigee organization is unknown." \
                --arg severity "2" \
                --arg expected "The Apigee organization lookup should return a definite answer" \
                --arg actual "Organization lookup returned HTTP $org_status: $api_msg" \
                --arg next_steps "Confirm the service account holds roles/apigee.readOnlyAdmin on project '$GCP_PROJECT_ID'. Set APIGEE_ORG explicitly if the org belongs to a different project. A 403 that does NOT say the API is disabled is a permission problem, not an absent Apigee." \
                '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]')
            echo "$issues_json" > "$ISSUES_FILE"
            exit 0
            ;;
    esac
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
    # Not an issue: every deployment beyond the cap is recorded with state
    # UNKNOWN, and check_deployment_state.sh reports each one individually. An
    # aggregate here would be the same finding a second time.
    echo "NOTE: $raw_count deployment(s) in scope exceeds APIGEE_MAX_STATUS_CALLS ($APIGEE_MAX_STATUS_CALLS);"
    echo "      the remainder are recorded as UNKNOWN and reported by the deployment state check."
fi

echo "Retrieving runtime status for $raw_count deployment(s) (cap: $APIGEE_MAX_STATUS_CALLS)..."
deployments_json=$(apigee_enrich_deployments "$ORG" "$deployments_json")

echo "$deployments_json" > "$DEPLOYMENTS_FILE"
echo "$proxies_json" > "$PROXIES_FILE"

# Applicable: record the resolved org and the real collections.
jq -n --arg org "$ORG" \
      --argjson envs "$(apigee_list_environments "$ORG")" \
      --argjson proxies "$proxies_json" \
      --argjson deployments "$deployments_json" \
      '{applicable: true, status: "ok", organization: $org, reason: "organization_resolved",
        environments: $envs, proxies: $proxies, deployments: $deployments}' \
    > "$APIGEE_TOPOLOGY_FILE"

proxy_count=$(echo "$proxies_json" | jq length)
deploy_count=$(echo "$deployments_json" | jq length)
unknown_count=$(echo "$deployments_json" | jq '[.[] | select(.statusUnavailable == true)] | length')
echo "Discovered $proxy_count proxy(ies) with $deploy_count deployment(s)."

if [ "$unknown_count" -gt 0 ]; then
    # Not an issue here either: check_deployment_state.sh raises one per
    # deployment, naming the proxy and environment. Repeating the count would
    # cost a second triage for findings already on the list.
    echo "NOTE: $unknown_count of $deploy_count deployment(s) have UNKNOWN runtime state;"
    echo "      each is reported individually by the deployment state check."
fi

echo ""
echo "--- Proxy summary (name / revisions / latest) ---"
echo "$proxies_json" | jq -r '.[] | "\(.name) / \((.revision // []) | length) revision(s) / latest \(.latestRevisionId // "unknown")"'
echo ""
echo "--- Deployment summary (proxy / env / revision / state) ---"
echo "$deployments_json" | jq -r '.[] | "\(.apiProxy) / \(.environment) / rev \(.revision) / \(.state // "N/A")"'

echo "$issues_json" > "$ISSUES_FILE"
echo "Discovery complete. Found $(jq length "$ISSUES_FILE") issue(s)."
