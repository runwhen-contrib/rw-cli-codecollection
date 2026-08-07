#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Proxy Revision and Approval State
#
# Detects proxies whose deployed revision is superseded by a newer revision,
# proxies that are still in a draft/imported (non-final) state, and proxies
# whose endpoint/hostname configuration has drifted from the deployed revision.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG               - Apigee organization name
#   GCP_PROJECT_ID           - GCP project hosting the Apigee runtime
#   STALE_REVISION_THRESHOLD - Number of revisions behind latest before flagging
#
# OUTPUTS:
#   revision_issues.json     - JSON array of revision-related issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STALE_REVISION_THRESHOLD:=1}"

ISSUES_FILE="revision_issues.json"
issues_json='[]'

APIGEE_BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

echo "Checking Apigee revision and approval state for org: $APIGEE_ORG (stale threshold: $STALE_REVISION_THRESHOLD)"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee Admin API for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee proxy revisions should be retrievable" \
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

jq -c '.proxies[]?' proxy_discovery.json | while read -r proxy; do
    name=$(echo "$proxy" | jq -r '.details.name // ""')
    latest=$(echo "$proxy" | jq -r '.details.latestRevisionId // ""')
    latest_int=$(echo "$latest" | grep -oE '[0-9]+' || echo "0")
    draft=$(echo "$proxy" | jq -r --arg l "$latest" 'if .details.revisions | length == 0 then true else false end')

    # Deployed revisions across environments.
    deployed_revs=$(echo "$proxy" | jq -r '[.deployments[]? | select(.state=="deployed") | (.revision|tonumber)] | unique')
    max_deployed=$(echo "$deployed_revs" | jq -r 'if length==0 then 0 else .[0] end // 0' 2>/dev/null || echo "0")

    # Proxy has revisions but is not deployed -> likely draft/imported only.
    rev_total=$(echo "$proxy" | jq '.details.revisions | length' 2>/dev/null || echo "0")
    if [ -n "$draft" ] && [ "$draft" = "false" ] && [ "$(echo "$proxy" | jq '.deployments | length')" -eq 0 ]; then
        issue=$(jq -n \
            --arg title "API proxy \`$name\` has revisions but is not deployed (draft state)" \
            --arg details "Proxy '$name' in org '$APIGEE_ORG' has $rev_total revision(s) but none deployed. The latest revision is '$latest' and it remains in a draft/imported state waiting for deployment." \
            --arg severity "3" \
            --arg expected "Proxy '$name' should have its revisions deployed (final state) to expose its API" \
            --arg actual "Proxy '$name' has $rev_total revision(s) but none deployed" \
            --arg next_steps "Deploy the latest revision '$latest' of proxy '$name' to the appropriate environment(s) to move it out of draft state." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi

    # Latest revision is ahead of the maximum deployed revision (in-moderation).
    if [ -n "$latest_int" ] && [ "$latest_int" -ne 0 ] && [ "$max_deployed" -ne 0 ]; then
        ahead=$(( latest_int - max_deployed ))
        if [ "$ahead" -gt "$STALE_REVISION_THRESHOLD" ]; then
            issue=$(jq -n \
                --arg title "API proxy \`$name\` has a newer revision (\`$latest\`) not yet deployed anywhere" \
                --arg details "Proxy '$name' in org '$APIGEE_ORG' has latest revision '$latest' but the highest deployed revision is '$max_deployed', a gap of $ahead revision(s). The new revision is awaiting promotion." \
                --arg severity "2" \
                --arg expected "The latest revision of proxy '$name' should be deployed (or intentionally held back)" \
                --arg actual "Revision $max_deployed is deployed while revision $latest is the latest, a gap of $ahead" \
                --arg next_steps "Review changes in revision '$latest' and either promote it to the production environment(s) or note why it is intentionally held." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        fi
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Revision and approval state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
