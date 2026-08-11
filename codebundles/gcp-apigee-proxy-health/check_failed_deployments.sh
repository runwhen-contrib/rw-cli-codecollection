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
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

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
# Collected, then raised once -- see apigee_make_issue.
orphan_list=""; orphan_n=0
for proxy in $(echo "$proxies" | jq -r '.[]'); do
    deployed_in=$(echo "$deployments" | jq -c --arg p "$proxy" '[.[] | select(.apiProxy == $p)] | length')
    if [ "$deployed_in" = "0" ]; then
        latest=$(apigee_cached_latest_revision "$proxy")
        orphan_list="${orphan_list}  - ${proxy} (latest revision ${latest})"$'\n'
        orphan_n=$((orphan_n + 1))
    fi
done

if [ "$orphan_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies are not deployed to any environment in \`$GCP_PROJECT_ID\`" 3 \
        "Every proxy should be deployed to at least one environment to serve traffic" \
        "$orphan_n proxy(ies) have no deployment in any environment" \
        "Deploy each proxy listed in the details to its intended environment(s), or remove it if unused. Check for a failed deploy that left it unexposed." \
        "$orphan_n undeployed proxy(ies):"$'\n'"$orphan_list")" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Undeployed proxy check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
