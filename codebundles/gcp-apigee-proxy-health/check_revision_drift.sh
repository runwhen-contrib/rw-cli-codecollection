#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_revision_drift.sh
# Verifies the revision deployed in each environment matches the expected/latest
# revision and that environments do not diverge for a proxy. Flags a deployed
# revision that differs from the latest (stale logic live) and environments that
# silently fell back to an older revision after a failed deploy.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#   APIGEE_GCP_PROJECT - internal passthrough of project id (unused, for parity)
#
# OUTPUTS:
#   revision_drift_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="revision_drift_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping revision drift check."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

deployments=$(apigee_load_deployments)
proxies=$(apigee_load_proxies)

# Group deployments per proxy (proxy -> list of {environment, revision}).
echo "Checking revision drift across environments in org: $ORG"

for proxy in $(echo "$proxies" | jq -r '.[]'); do
    latest=$(apigee_latest_revision "$ORG" "$proxy")
    proxy_deployments=$(echo "$deployments" | jq -c --arg p "$proxy" '[.[] | select(.apiProxy == $p)]')

    count=$(echo "$proxy_deployments" | jq length)
    [ "$count" -eq 0 ] && continue

    echo -n "  Proxy '$proxy': latest revision = $latest; deployed envs: "
    echo "$proxy_deployments" | jq -r '.[] | "\(.environment)(rev \(.revision))"' | tr '\n' ' '; echo ""

    # Distinct revision numbers across all envs of this proxy -> drift if >1.
    distinct=$(echo "$proxy_deployments" | jq '[.[].revision] | unique | length')

    # Check each env against latest revision.
    echo "$proxy_deployments" | jq -c '.[]' | while read -r dep; do
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
            echo "$issues_json" > "$ISSUES_FILE"
        fi
    done

    # Cross-environment drift.
    if [ "$distinct" -gt 1 ]; then
        revs=$(echo "$proxy_deployments" | jq -r '[group_by(.revision) | .[] | (.[0].revision + ":" + (map(.environment) | join(",")))] | join("; ")')
        issue=$(jq -n \
            --arg title "Revision drift across environments for proxy \`$proxy\`" \
            --arg details "Proxy '$proxy' is running different revisions across environments: $revs. Environments have silently diverged." \
            --arg severity "2" \
            --arg expected "All environments should run the same (latest) revision for a proxy" \
            --arg actual "Environments diverged: $revs" \
            --arg next_steps "Align all environments to a single intended revision ($latest) and redeploy any environment that fell back to an older revision after a failed deploy." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Revision drift check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
