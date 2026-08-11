#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_revision_drift.sh
# Verifies the revision deployed in each environment matches the expected/latest
# revision and that environments do not diverge for a proxy. Flags a deployed
# revision that differs from the latest (stale logic live) and environments that
# silently fell back to an older revision after a failed deploy.
#
# Latest revision comes from the cached /apis?includeRevisions=true payload
# (latestRevisionId), so this check makes no additional API calls.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#
# OUTPUTS:
#   revision_drift_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="revision_drift_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping revision drift check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

deployments=$(apigee_load_deployments)
proxies=$(apigee_load_proxies)

echo "Checking revision drift across environments in org: $ORG"

# Drift is a property of DEPLOYED revisions. With no deployments there is no
# drift to observe -- which is not the same as no drift.
if [ "$(echo "$deployments" | jq length)" -eq 0 ]; then
    echo "No deployments in scope; there is no revision drift to judge."
fi
# Collected per condition, raised once each -- see apigee_make_issue.
stale_list=""  ; stale_n=0
drift_list=""  ; drift_n=0

for proxy in $(echo "$proxies" | jq -r '.[]'); do
    latest=$(apigee_cached_latest_revision "$proxy")
    proxy_deployments=$(echo "$deployments" | jq -c --arg p "$proxy" '[.[] | select(.apiProxy == $p)]')

    count=$(echo "$proxy_deployments" | jq length)
    [ "$count" -eq 0 ] && continue

    echo -n "  Proxy '$proxy': latest revision = $latest; deployed envs: "
    echo "$proxy_deployments" | jq -r '.[] | "\(.environment)(rev \(.revision))"' | tr '\n' ' '; echo ""

    distinct=$(echo "$proxy_deployments" | jq '[.[].revision] | unique | length')

    # Process substitution keeps the loop in this shell: on the right of a pipe
    # it would run in a subshell and every append below would be lost.
    while read -r dep; do
        env=$(echo "$dep" | jq -r '.environment')
        rev=$(echo "$dep" | jq -r '.revision')
        if [ "$rev" != "$latest" ]; then
            stale_list="${stale_list}  - ${proxy} (env ${env}): running revision ${rev}, latest is ${latest}"$'\n'
            stale_n=$((stale_n + 1))
        fi
    done < <(echo "$proxy_deployments" | jq -c '.[]')

    if [ "$distinct" -gt 1 ]; then
        revs=$(echo "$proxy_deployments" | jq -r '[group_by(.revision) | .[] | ((.[0].revision | tostring) + ":" + (map(.environment) | join(",")))] | join("; ")')
        drift_list="${drift_list}  - ${proxy}: ${revs} (latest is ${latest})"$'\n'
        drift_n=$((drift_n + 1))
    fi
done

if [ "$stale_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies are not running their latest revision" 2 \
        "Every deployed revision should match the proxy's latest revision" \
        "$stale_n deployment(s) are running a revision older than the latest" \
        "Stale logic may be live. Deploy the latest revision to each environment listed in the details. If a given drift is intentional, annotate that proxy to suppress it." \
        "$stale_n deployment(s) behind the latest revision:"$'\n'"$stale_list")" '. += [$i]')
fi

if [ "$drift_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have revision drift across environments" 2 \
        "All environments should run the same revision for a given proxy" \
        "$drift_n proxy(ies) run different revisions in different environments" \
        "Environments have silently diverged. Align each proxy listed in the details to a single intended revision, and redeploy any environment that fell back to an older revision after a failed deploy." \
        "$drift_n proxy(ies) with cross-environment drift:"$'\n'"$drift_list")" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Revision drift check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
