#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_deployment_state.sh
# For each proxy deployment, verifies the runtime state is READY (deployed)
# with an empty errors[] array. Flags any deployment in ERROR/PROGRESSING state
# or with non-empty errors[], which means the deploy did not fully take effect.
#
# Runtime state comes from the deployment STATUS view, merged onto each
# deployment by discover_proxies.sh. Deployments whose status could not be read
# carry state UNKNOWN and are reported as such -- never as healthy.
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
apigee_init_issues "$ISSUES_FILE"
apigee_set_measured deployment_state false
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping deployment state check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

deployments=$(apigee_load_deployments)
total=$(echo "$deployments" | jq length)
echo "Checking deployment state for $total deployment(s) in org: $ORG"

# With no deployments there is no deployment state to judge. Reporting that as
# "0 issues" would score an empty org identically to a flawless one.
if [ "$total" -gt 0 ]; then
    apigee_set_measured deployment_state true
else
    echo "No deployments in scope; deployment state is unmeasured, not healthy."
fi

# Process substitution, not a pipe: a `while read` on the right of a pipe runs
# in a subshell and every issue appended there is discarded when it exits.
while read -r dep; do
    proxy=$(echo "$dep" | jq -r '.apiProxy // "unknown"')
    env=$(echo "$dep" | jq -r '.environment // "unknown"')
    revision=$(echo "$dep" | jq -r '.revision // "unknown"')
    state=$(echo "$dep" | jq -r '.state // "UNKNOWN"')
    errors=$(echo "$dep" | jq -c '.errors // []')

    echo -n "  $proxy ($env rev $revision): state=$state"

    case "$state" in
        ERROR)
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
            continue
            ;;
        PROGRESSING)
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
            continue
            ;;
        UNKNOWN)
            echo " -> status unavailable"
            issue=$(jq -n \
                --arg title "Deployment status unavailable for proxy \`$proxy\` (env \`$env\`)" \
                --arg details "Runtime status for $proxy revision $revision in environment '$env' could not be read, so its deployment health is unknown. Reason: $(echo "$dep" | jq -r '.statusSkippedReason // "unknown"')" \
                --arg severity "3" \
                --arg expected "The deployment status view should report a runtime state for every deployment" \
                --arg actual "Proxy '$proxy' in env '$env' has no readable runtime state" \
                --arg next_steps "Confirm the service account holds roles/apigee.readOnlyAdmin, check APIGEE_MAX_STATUS_CALLS is not capping this org, then re-run discovery." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            continue
            ;;
    esac

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
        continue
    fi

    echo " -> OK"
done < <(echo "$deployments" | jq -c '.[]')

echo "$issues_json" > "$ISSUES_FILE"
echo "Deployment state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
