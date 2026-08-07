#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Environment Deployment Coverage
#
# Identifies environments with no deployed proxies. An environment that should
# host live traffic but has zero active deployments is flagged, since consumers
# will receive no proxy responses from it.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG          - Apigee organization name
#   GCP_PROJECT_ID      - GCP project hosting the Apigee runtime
#
# OUTPUTS:
#   coverage_issues.json - JSON array of environment coverage issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="coverage_issues.json"
issues_json='[]'

APIGEE_BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

echo "Checking Apigee environment deployment coverage for org: $APIGEE_ORG"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee Admin API for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee environments should be retrievable" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the service account has roles/apigee.readOnlyAdmin on project $GCP_PROJECT_ID." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

api_get() {
    curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/json" "$@"
}

if [ ! -f "proxy_discovery.json" ]; then
    ./discover_proxies.sh >/dev/null 2>&1 || true
    if [ -f "proxy_discovery_issues.json" ] && [ "$(jq length proxy_discovery_issues.json)" -gt 0 ]; then
        cp proxy_discovery_issues.json "$ISSUES_FILE"
        exit 0
    fi
fi

if [ ! -f "proxy_discovery.json" ]; then
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

env_count=$(jq '.environments | length' proxy_discovery.json)
if [ "$env_count" -eq 0 ]; then
    echo "No environments found in org $APIGEE_ORG."
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

jq -c '.environments[]?' proxy_discovery.json | while read -r env; do
    name=$(echo "$env" | jq -r '.name // ""')
    dep_count=$(echo "$env" | jq '[.deployments[]? | select(.state=="deployed")] | length')

    if [ "$dep_count" -eq 0 ]; then
        issue=$(jq -n \
            --arg title "Apigee environment \`$name\` has no active proxy deployments" \
            --arg details "Environment '$name' in org '$APIGEE_ORG' currently hosts zero deployed API proxies. Any hostnames bound to this environment in an envgroup will return no proxy responses, causing consumer errors." \
            --arg severity "4" \
            --arg expected "Environment '$name' should have at least one deployed proxy if it hosts traffic" \
            --arg actual "Environment '$name' has no deployed proxies" \
            --arg next_steps "Deploy an API proxy to environment '$name', or if the environment is unused/deprecated, remove it and its envgroup bindings from the org to avoid serving empty traffic." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    else
        echo "  Environment '$name': $dep_count active deployment(s) - OK."
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Environment coverage check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
