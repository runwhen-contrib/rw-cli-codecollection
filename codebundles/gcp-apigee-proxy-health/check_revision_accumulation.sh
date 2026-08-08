#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_revision_accumulation.sh
# Identifies proxies accumulating many undeployed/superseded revisions without
# cleanup, and proxies with a large number of stale revisions. Informational
# housekeeping signal (severity 4) to prevent drift and deploy confusion.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#   REVISION_ACCUMULATION_THRESHOLD - stale revision count to flag (default 20)
#
# OUTPUTS:
#   revision_accumulation_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
REVISION_ACCUMULATION_THRESHOLD="${REVISION_ACCUMULATION_THRESHOLD:-20}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="revision_accumulation_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping revision accumulation check."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

proxies=$(apigee_load_proxies)
deployments=$(apigee_load_deployments)

echo "Checking revision accumulation for proxies in org: $ORG (threshold: $REVISION_ACCUMULATION_THRESHOLD)"

for proxy in $(echo "$proxies" | jq -r '.[]'); do
    revisions=$(apigee_list_revisions "$ORG" "$proxy")
    total=$(echo "$revisions" | jq length)
    # How many revisions are actually deployed (across all envs) for this proxy?
    deployed_revs=$(echo "$deployments" | jq '[.[] | select(.apiProxy == $proxy_of_interest) | .revision] | unique | length' --arg proxy_of_interest "$proxy")
    stale=$(( total - deployed_revs ))

    echo -n "  Proxy '$proxy': $total revisions, $deployed_revs deployed, $stale stale. "

    if [ "$total" -ge "$REVISION_ACCUMULATION_THRESHOLD" ]; then
        echo "FLAG"
        issue=$(jq -n \
            --arg title "Proxy \`$proxy\` has accumulated $total revisions" \
            --arg details "Proxy '$proxy' has $total total revisions but only $deployed_revs deployed ($stale stale/superseded). Large revision count invites drift and deploy confusion." \
            --arg severity "4" \
            --arg expected "Proxies should have a manageable number of revisions, with stale revisions cleaned up" \
            --arg actual "Proxy '$proxy' has $total revisions" \
            --arg next_steps "Housekeeping: delete superseded/undeployed revisions of '$proxy' (bundle/netron), keeping only those still deployed or needed for rollback. See https://cloud.google.com/apigee/docs/api-platform/deploy/delete-revisions." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    else
        echo "OK"
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Revision accumulation check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
