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

for proxy in $(echo "$proxies" | jq -r '.[]'); do
    latest=$(apigee_cached_latest_revision "$proxy")
    proxy_deployments=$(echo "$deployments" | jq -c --arg p "$proxy" '[.[] | select(.apiProxy == $p)]')

    count=$(echo "$proxy_deployments" | jq length)
    [ "$count" -eq 0 ] && continue

    echo -n "  Proxy '$proxy': latest revision = $latest; deployed envs: "
    echo "$proxy_deployments" | jq -r '.[] | "\(.environment)(rev \(.revision))"' | tr '\n' ' '; echo ""

    # Distinct revision numbers across all envs of this proxy -> drift if >1.
    distinct=$(echo "$proxy_deployments" | jq '[.[].revision] | unique | length')

    # Check each env against latest revision. Process substitution keeps the
    # loop in this shell: on the right of a pipe it would run in a subshell and
    # every issue appended below would be lost when that subshell exited.
    while read -r dep; do
        env=$(echo "$dep" | jq -r '.environment')
        rev=$(echo "$dep" | jq -r '.revision')
        if [ "$rev" != "$latest" ]; then
            issue=$(jq -n \
                --arg title "Proxy \`$proxy\` in env \`$env\` is not on latest revision" \
                --arg details "Proxy '$proxy' is deployed on revision $rev in environment '$env' but the latest available revision is $latest. Stale logic may be live." \
                --arg severity "2" \
                --arg expected "Deployed revision should match the latest revision" \
                --arg actual "Env '$env' runs revision $rev (latest is $latest)" \
                --arg next_steps "Deploy revision $latest to '$env' so the intended logic is live. If this drift is intentional, annotate the proxy to suppress the alert." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(echo "$proxy_deployments" | jq -c '.[]')

    # Cross-environment drift.
    if [ "$distinct" -gt 1 ]; then
        revs=$(echo "$proxy_deployments" | jq -r '[group_by(.revision) | .[] | ((.[0].revision | tostring) + ":" + (map(.environment) | join(",")))] | join("; ")')
        issue=$(jq -n \
            --arg title "Revision drift across environments for proxy \`$proxy\`" \
            --arg details "Proxy '$proxy' is running different revisions across environments: $revs. Environments have silently diverged." \
            --arg severity "2" \
            --arg expected "All environments should run the same (latest) revision for a proxy" \
            --arg actual "Environments diverged: $revs" \
            --arg next_steps "Align all environments to a single intended revision ($latest) and redeploy any environment that fell back to an older revision after a failed deploy." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done

echo "$issues_json" > "$ISSUES_FILE"
echo "Revision drift check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
