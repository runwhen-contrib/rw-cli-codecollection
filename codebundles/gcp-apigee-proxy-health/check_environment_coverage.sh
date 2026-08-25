#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_environment_coverage.sh
# Flags environments in the org that host ZERO API proxy deployments.
#
# This is the environment axis of the same inventory the other checks read from
# the proxy axis, and it reaches a finding none of them can. check_failed_
# deployments.sh asks "is this proxy deployed anywhere?"; an org whose proxies
# are all deployed to prod answers yes for every proxy while an empty `test`
# environment sits there serving nothing. Only this check sees that.
#
# Deliberately narrow: "zero deployments", not "zero HEALTHY deployments". An
# environment whose deployments are all in ERROR is reported by
# check_deployment_state.sh, and repeating it here would cost a second triage
# for a finding already on the list.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#   ENVIRONMENTS       - optional; comma-separated env filter ("All" = all)
#   PROXIES            - optional; comma-separated proxy filter ("All" = all)
#
# OUTPUTS:
#   environment_coverage_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENVIRONMENTS="${ENVIRONMENTS:-All}"
PROXIES="${PROXIES:-All}"
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="environment_coverage_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

# Discovery runs in Suite Initialization and fails the suite when it could not
# build an inventory, so by the time this runs the topology is guaranteed to
# exist. A missing one means something is genuinely wrong -- reading it as an
# empty estate here would report "no issues found" for a check that never
# looked at anything.
if [ ! -f "$APIGEE_TOPOLOGY_FILE" ]; then
    echo "ERROR: $APIGEE_TOPOLOGY_FILE is missing. Discovery runs in Suite Initialization;" >&2
    echo "       run discover_proxies.sh first if you are invoking this script directly." >&2
    exit 1
fi

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping environment coverage check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

# A PROXIES filter removes deployments from the inventory, so an environment can
# look uncovered purely because the proxies it hosts were filtered out. That
# would be a finding manufactured by configuration, so refuse to judge instead.
# The ENVIRONMENTS filter is different: it narrows WHICH environments are judged,
# which is applied below rather than being a reason to skip.
proxy_filter="$(apigee_expand_csv "$PROXIES")"
if [ "$proxy_filter" != "All" ]; then
    echo "PROXIES is scoped to '$proxy_filter', so deployments for other proxies are not in"
    echo "the inventory and an environment hosting only those would look empty."
    echo "There is no environment coverage to judge under a proxy filter; skipping."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# The topology records every environment the org reports, unfiltered, while the
# deployments it records ARE filtered by ENVIRONMENTS. Judging the full list
# against filtered deployments would flag every out-of-scope environment as
# uncovered, so narrow the list to what this run actually looked at.
env_filter="$(apigee_expand_csv "$ENVIRONMENTS")"
if [ "$env_filter" = "All" ]; then
    environments=$(jq -c '.environments // []' "$APIGEE_TOPOLOGY_FILE")
else
    environments=$(jq -c --arg f "$env_filter" \
        '[(.environments // [])[] | select(. as $e | ($f | split(",")) | index($e))]' \
        "$APIGEE_TOPOLOGY_FILE")
fi

deployments=$(apigee_load_deployments)
env_count=$(echo "$environments" | jq length)
echo "Checking deployment coverage for $env_count environment(s) in org: $ORG"

if [ "$env_count" -eq 0 ]; then
    echo "No environments in scope; there is no environment coverage to judge."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Findings are COLLECTED, then raised as ONE issue. The SLX is org-scoped, so an
# issue per environment would split one class of problem across N issues and
# churn as environments are added and retired.
#
# Process substitution, not a pipe: a `while read` on the right of a pipe runs in
# a subshell and every list appended there is discarded when it exits.
uncovered_list=""; uncovered_n=0
while IFS= read -r env; do
    [ -z "$env" ] && continue
    dep_n=$(echo "$deployments" | jq --arg e "$env" '[.[] | select(.environment == $e)] | length')
    echo -n "  $env: $dep_n deployment(s)"
    if [ "$dep_n" -eq 0 ]; then
        echo " -> no proxies deployed"
        uncovered_list="${uncovered_list}  - ${env}"$'\n'
        uncovered_n=$((uncovered_n + 1))
    else
        echo " -> OK"
    fi
done < <(echo "$environments" | jq -r '.[]')

if [ "$uncovered_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee environments have no API proxies deployed in org \`$ORG\`" 4 \
        "Every environment in the organization should host at least one deployed API proxy" \
        "$uncovered_n environment(s) host no deployed API proxies" \
        "Deploy an API proxy to each environment listed in the details, or retire the environment and its environment-group bindings. A hostname routed to an environment with nothing deployed returns an edge-level error to callers rather than a proxy response. See https://cloud.google.com/apigee/docs/api-platform/deploy/deploy-api-proxy." \
        "$uncovered_n environment(s) with no deployed API proxies:"$'\n'"$uncovered_list")" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Environment coverage check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
