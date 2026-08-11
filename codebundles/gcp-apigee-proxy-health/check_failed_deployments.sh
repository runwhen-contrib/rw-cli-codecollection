#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_failed_deployments.sh
# Detects proxy revisions whose deployment failed (a revision in ERROR state,
# or a newer revision not replacing an older one), and proxies that are expected
# but not deployed to any environment. Flags proxies that appear orphaned or
# stuck after a failed deploy.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#
# OUTPUTS:
#   failed_deployments_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="failed_deployments_issues.json"
apigee_init_issues "$ISSUES_FILE"
apigee_set_measured failed_deployments false
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping failed deployment check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

deployments=$(apigee_load_deployments)
proxies=$(apigee_load_proxies)

echo "Checking for failed / stuck deployments in org: $ORG"

# This check judges proxies (are they deployed? did a deploy fail?), so it is
# measured as soon as the org has at least one proxy -- including proxies that
# are deployed nowhere, which is exactly what it looks for.
if [ "$(echo "$proxies" | jq length)" -gt 0 ]; then
    apigee_set_measured failed_deployments true
else
    echo "No proxies in scope; failed/undeployed status is unmeasured, not healthy."
fi

# 1) Deployments stuck in ERROR state (a new revision could not replace old one).
#    `state` is merged on by discovery from the deployment status view; it is
#    absent from every deployment LIST response.
while read -r dep; do
    proxy=$(echo "$dep" | jq -r '.apiProxy')
    env=$(echo "$dep" | jq -r '.environment')
    revision=$(echo "$dep" | jq -r '.revision')
    errors=$(echo "$dep" | jq -c '.errors // []')
    issue=$(jq -n \
        --arg title "Failed deploy for proxy \`$proxy\` revision $revision (env \`$env\`)" \
        --arg details "Revision $revision of proxy '$proxy' is in ERROR state in environment '$env' and has not replaced the prior revision. errors[]: $errors" \
        --arg severity "2" \
        --arg expected "The newest revision should deploy successfully and replace older ones" \
        --arg actual "Revision $revision of '$proxy' failed to deploy in '$env'" \
        --arg next_steps "Fix the proxy bundle / deployment error and redeploy revision $revision, or clean up the failed revision." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
done < <(echo "$deployments" | jq -c '.[] | select(.state == "ERROR")')

# 2) Proxies that exist but are NOT deployed to any environment (orphaned).
#    Presence of a deployment record is what "deployed" means here. Gating this
#    on state == "READY" would report every proxy in the org as undeployed
#    whenever runtime status is unavailable; deployments that exist but are
#    unhealthy are already reported above and by check_deployment_state.sh.
for proxy in $(echo "$proxies" | jq -r '.[]'); do
    deployed_in=$(echo "$deployments" | jq -c --arg p "$proxy" '[.[] | select(.apiProxy == $p)] | length')
    if [ "$deployed_in" = "0" ]; then
        latest=$(apigee_cached_latest_revision "$proxy")
        issue=$(jq -n \
            --arg title "Proxy \`$proxy\` is not deployed to any environment" \
            --arg details "Proxy '$proxy' (latest revision $latest) has no deployment in any environment. It is orphaned or was never deployed." \
            --arg severity "3" \
            --arg expected "Every proxy should be deployed to at least one environment to serve traffic" \
            --arg actual "Proxy '$proxy' has no active deployment" \
            --arg next_steps "Deploy a revision of '$proxy' to the intended environment(s), or remove the unused proxy. Check for a failed deploy that left it unexposed." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done

echo "$issues_json" > "$ISSUES_FILE"
echo "Failed deployment check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
