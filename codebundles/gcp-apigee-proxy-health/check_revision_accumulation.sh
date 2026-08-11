#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_revision_accumulation.sh
# Identifies proxies accumulating many undeployed/superseded revisions without
# cleanup, and proxies with a large number of stale revisions. Informational
# housekeeping signal (severity 4) to prevent drift and deploy confusion.
#
# Revision counts come from the cached /apis?includeRevisions=true payload, so
# this check makes no additional API calls.
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
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="revision_accumulation_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping revision accumulation check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

proxies=$(apigee_load_proxies)
deployments=$(apigee_load_deployments)

echo "Checking revision accumulation for proxies in org: $ORG (threshold: $REVISION_ACCUMULATION_THRESHOLD)"
# Collected, then raised once. The revision COUNT is deliberately kept out of
# the title: it grows on every import while the condition holds, so a title
# carrying it would mint a fresh issue on every deploy.
acc_list=""; acc_n=0
for proxy in $(echo "$proxies" | jq -r '.[]'); do
    revisions=$(apigee_cached_revisions "$proxy")
    total=$(echo "$revisions" | jq length)
    deployed_revs=$(echo "$deployments" | jq --arg p "$proxy" '[.[] | select(.apiProxy == $p) | .revision] | unique | length')
    stale=$(( total - deployed_revs ))

    echo -n "  Proxy '$proxy': $total revisions, $deployed_revs deployed, $stale stale. "

    if [ "$total" -ge "$REVISION_ACCUMULATION_THRESHOLD" ]; then
        echo "FLAG"
        acc_list="${acc_list}  - ${proxy}: ${total} revisions, ${deployed_revs} deployed, ${stale} stale/superseded"$'\n'
        acc_n=$((acc_n + 1))
    else
        echo "OK"
    fi
done

if [ "$acc_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have accumulated excess revisions in \`$GCP_PROJECT_ID\`" 4 \
        "Proxies should keep a manageable number of revisions, with stale ones cleaned up" \
        "$acc_n proxy(ies) are at or above the $REVISION_ACCUMULATION_THRESHOLD-revision threshold" \
        "Housekeeping: delete superseded/undeployed revisions of the proxies listed in the details, keeping only those still deployed or needed for rollback. See https://cloud.google.com/apigee/docs/api-platform/deploy/delete-revisions." \
        "$acc_n proxy(ies) at or above the threshold of $REVISION_ACCUMULATION_THRESHOLD:"$'\n'"$acc_list")" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Revision accumulation check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
