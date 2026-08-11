#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_failed_deployments.sh
# Detects proxies that exist but are not deployed to any environment -- orphaned,
# or left unexposed by a deploy that never landed.
#
# Deployment ERROR state is deliberately NOT reported here; check_deployment_state.sh
# owns it. See the note at the check below.
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
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping failed deployment check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

deployments=$(apigee_load_deployments)
proxies=$(apigee_load_proxies)

echo "Checking for undeployed / orphaned proxies in org: $ORG"

# Say so in the report when there is nothing to judge, rather than letting a
# clean result read as a verified one.
if [ "$(echo "$proxies" | jq length)" -eq 0 ]; then
    echo "No proxies in scope; there is nothing to report as failed or undeployed."
fi

# Deployments in ERROR state are NOT reported here: check_deployment_state.sh
# owns deployment state and already raises one issue per ERROR deployment,
# alongside PROGRESSING, UNKNOWN and non-empty errors[]. Reporting the same
# condition from two tasks makes an operator triage one fault twice.
#
# This check owns the finding nothing else can reach: a proxy that exists but
# is deployed nowhere.

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
echo "Undeployed proxy check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
