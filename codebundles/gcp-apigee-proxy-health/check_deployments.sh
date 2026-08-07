#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Proxy Deployment Health
#
# For each API proxy, verifies the deployed revision matches the latest
# available revision and that deployments have a state of 'deployed'. Flags
# proxies that are not deployed at all, are in an error/pending state, or are
# running a stale (non-latest) revision.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG               - Apigee organization name
#   GCP_PROJECT_ID           - GCP project hosting the Apigee runtime
#   STALE_REVISION_THRESHOLD - Number of revisions behind latest before flagging
#   INCLUDE_DRAFT_PROXIES    - Whether to flag non-deployed/draft proxies
#
# OUTPUTS:
#   deployment_issues.json   - JSON array of deployment issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STALE_REVISION_THRESHOLD:=1}"
: "${INCLUDE_DRAFT_PROXIES:=true}"

ISSUES_FILE="deployment_issues.json"
issues_json='[]'

APIGEE_BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

echo "Checking Apigee deployment health for org: $APIGEE_ORG (stale threshold: $STALE_REVISION_THRESHOLD, include drafts: $INCLUDE_DRAFT_PROXIES)"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee Admin API for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee proxy deployments should be retrievable" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the service account has roles/apigee.readOnlyAdmin on project $GCP_PROJECT_ID." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

api_get() {
    curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/json" "$@"
}

# Build the discovery dump if not already present.
if [ ! -f "proxy_discovery.json" ]; then
    ./discover_proxies.sh >/dev/null 2>&1 || true
    if [ -f "proxy_discovery_issues.json" ] && [ "$(jq length proxy_discovery_issues.json)" -gt 0 ]; then
        cp proxy_discovery_issues.json "$ISSUES_FILE"
        exit 0
    fi
fi

if [ ! -f "proxy_discovery.json" ]; then
    echo "[]" > "$ISSUES_FILE"
    echo "Proxy discovery data unavailable; no deployment checks run."
    exit 0
fi

jq -c '.proxies[]?' proxy_discovery.json 2>/dev/null | while read -r proxy; do
    name=$(echo "$proxy" | jq -r '.details.name // ""')
    latest=$(echo "$proxy" | jq -r '.details.latestRevisionId // ""')
    dep_count=$(echo "$proxy" | jq '.deployments | length')

    if [ "$dep_count" -eq 0 ]; then
        if [ "$INCLUDE_DRAFT_PROXIES" = "true" ]; then
            issue=$(jq -n \
                --arg title "API proxy \`$name\` is not deployed to any environment" \
                --arg details "Proxy '$name' in org '$APIGEE_ORG' has no active deployment across any environment. It may be in draft/imported state or has been intentionally deactivated." \
                --arg severity "3" \
                --arg expected "API proxy '$name' should be deployed to at least one environment" \
                --arg actual "Proxy '$name' has zero deployments" \
                --arg next_steps "Deploy the latest revision of '$name' to the intended environment(s) via the Apigee UI/API, or remove/archive the proxy if it is no longer needed." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        else
            echo "  Proxy '$name': not deployed (ignored, INCLUDE_DRAFT_PROXIES=false)."
        fi
        continue
    fi

    # latest as integer (revision IDs are numeric in Apigee X)
    latest_int=$(echo "$latest" | grep -oE '[0-9]+' || echo "0")

    deployments_json=$(echo "$proxy" | jq -c '.deployments[]?')
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        env=$(echo "$dep" | jq -r '.environment // ""')
        rev=$(echo "$dep" | jq -r '.revision // ""')
        state=$(echo "$dep" | jq -r '.state // ""')
        rev_int=$(echo "$rev" | grep -oE '[0-9]+' || echo "0")

        if [ "$state" != "deployed" ]; then
            issue=$(jq -n \
                --arg title "API proxy \`$name\` has a deployment in non-deployed state" \
                --arg details "Proxy '$name' environment '$env' revision '$rev' has state '$state' (expected 'deployed') in org '$APIGEE_ORG'." \
                --arg severity "4" \
                --arg expected "All proxy deployments should have a state of 'deployed'" \
                --arg actual "Deployment for '$name' in '$env' is in state '$state'" \
                --arg next_steps "Investigate why the deployment is '$state' (e.g., error, pending, undeployed). Redeploy the proxy revision or check the Apigee deployment logs." \
                '{title:$title,details:$details,severity:($severity|tonumber),"expected":$expected,"actual":$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        fi

        # stale revision check: deployed revision trails latest by more than threshold
        if [ -n "$latest_int" ] && [ "$latest_int" -ne 0 ] && [ -n "$rev_int" ] && [ "$rev_int" -ne 0 ]; then
            behind=$(( latest_int - rev_int ))
            if [ "$behind" -gt "$STALE_REVISION_THRESHOLD" ]; then
                issue=$(jq -n \
                    --arg title "API proxy \`$name\` is running a stale revision in \`$env\`" \
                    --arg details "Proxy '$name' in environment '$env' is running revision '$rev' while the latest revision is '$latest' (a difference of $behind revision(s), threshold $STALE_REVISION_THRESHOLD) in org '$APIGEE_ORG'." \
                    --arg severity "3" \
                    --arg expected "Deployed revision should be within $STALE_REVISION_THRESHOLD of the latest revision" \
                    --arg actual "Proxy '$name' in '$env' is $behind revision(s) behind the latest" \
                    --arg next_steps "Review the proxy changes between revision $rev and $latest, validate in a test environment, then deploy the latest revision '$latest' to environment '$env'." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            elif [ "$behind" -ge 1 ]; then
                echo "  Proxy '$name' in '$env': revision $rev vs latest $latest ($behind behind, within threshold)."
            fi
        fi
    done <<< "$deployments_json"
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Deployment health check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
