#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_deployment_state.sh
# For each proxy deployment, verifies the runtime state is READY (deployed)
# with an empty errors[] array. Flags any deployment in ERROR/PROGRESSING state
# or with non-empty errors[], which means the deploy did not fully take effect.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#
# OUTPUTS:
#   deployment_state_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="deployment_state_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping deployment state check."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

deployments=$(apigee_load_deployments)
total=$(echo "$deployments" | jq length)
echo "Checking deployment state for $total deployment(s) in org: $ORG"

echo "$deployments" | jq -c '.[]' | while read -r dep; do
    proxy=$(echo "$dep" | jq -r '.apiProxy // "unknown"')
    env=$(echo "$dep" | jq -r '.environment // "unknown"')
    revision=$(echo "$dep" | jq -r '.revision // "unknown"')
    state=$(echo "$dep" | jq -r '.state // "RUNTIME_STATE_UNSPECIFIED"')
    errors=$(echo "$dep" | jq -c '.errors // []')

    echo -n "  $proxy ($env rev $revision): state=$state"

    if [ "$state" = "ERROR" ]; then
        echo " -> ERROR"
        issue=$(jq -n \
            --arg title "Deployment in error state for proxy \`$proxy\` (env \`$env\`)" \
            --arg details "Deployment of $proxy revision $revision in environment '$env' is in ERROR state. errors[]: $errors" \
            --arg severity "2" \
            --arg expected "Proxy deployment state should be READY with no errors" \
            --arg actual "Proxy '$proxy' in env '$env' is in ERROR state" \
            --arg next_steps "The deployment did not take effect. Redeploy revision $revision to '$env' or investigate the reported error(s). See https://cloud.google.com/apigee/docs/api-platform/deploy/deploy-api-proxy for deployment guidance." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
        continue
    fi

    if [ "$state" = "PROGRESSING" ]; then
        echo " -> PROGRESSING"
        issue=$(jq -n \
            --arg title "Deployment still progressing for proxy \`$proxy\` (env \`$env\`)" \
            --arg details "Deployment of $proxy revision $revision in environment '$env' is in PROGRESSING state; the runtime has not fully loaded it yet." \
            --arg severity "2" \
            --arg expected "Proxy deployment state should be READY" \
            --arg actual "Proxy '$proxy' in env '$env' is still PROGRESSING" \
            --arg next_steps "Wait for the deployment to reach READY. If it stays PROGRESSING, redeploy or check runtime health." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
        continue
    fi

    if [ "$errors" != "[]" ] && [ -n "$errors" ]; then
        echo " -> errors[] present"
        issue=$(jq -n \
            --arg title "Deployment reporting errors for proxy \`$proxy\` (env \`$env\`)" \
            --arg details "Deployment of $proxy revision $revision in environment '$env' has a non-empty errors[] array: $errors" \
            --arg severity "2" \
            --arg expected "Deployment errors[] should be empty when the proxy is serving" \
            --arg actual "Deployment has errors: $errors" \
            --arg next_steps "Investigate the deployment errors for '$proxy' in '$env'; the proxy may be degraded though reported READY." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
        continue
    fi

    echo " -> OK"
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Deployment state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
