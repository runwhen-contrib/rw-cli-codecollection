#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate Apigee Proxy Health Summary
#
# Aggregates all proxy, deployment, environment, and runtime findings into a
# consolidated health summary (proxy totals, deployed vs not-deployed, stale
# revisions, at-risk environments) with an overall verdict.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG               - Apigee organization name
#   GCP_PROJECT_ID           - GCP project hosting the Apigee runtime
#   STALE_REVISION_THRESHOLD - Number of revisions behind latest before flagging
#
# OUTPUTS:
#   proxy_summary_report.json - Consolidated health summary object
#   summary_issues.json      - JSON array of summary-level issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${STALE_REVISION_THRESHOLD:=1}"

ISSUES_FILE="summary_issues.json"
REPORT_FILE="proxy_summary_report.json"
issues_json='[]'

APIGEE_BASE="https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG"

echo "Generating Apigee proxy health summary for org: $APIGEE_ORG"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Apigee Admin API for org \`$APIGEE_ORG\`" \
        --arg details "Unable to obtain an access token via gcloud for the Apigee Admin API." \
        --arg severity "4" \
        --arg expected "Apigee health summary should be generatable" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the service account has roles/apigee.readOnlyAdmin and roles/monitoring.viewer on project $GCP_PROJECT_ID." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "{}" > "$REPORT_FILE"
    exit 0
fi

api_get() {
    curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/json" "$@"
}

if [ ! -f "proxy_discovery.json" ]; then
    ./discover_proxies.sh >/dev/null 2>&1 || true
fi

if [ ! -f "proxy_discovery.json" ]; then
    echo "{}" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    echo "No proxy discovery data available; summary not generated."
    exit 0
fi

# Recompute per-proxy deployment status from the discovery dump.
total=$(jq '.proxies | length' proxy_discovery.json)
deployed=0
not_deployed=0
stale=0
env_total=$(jq '.environments | length' proxy_discovery.json)
empty_envs=0

while IFS= read -r proxy; do
    [ -z "$proxy" ] && continue
    dep_len=$(echo "$proxy" | jq '.deployments | length')
    latest=$(echo "$proxy" | jq -r '.details.latestRevisionId // "0"')
    latest_int=$(echo "$latest" | grep -oE '[0-9]+' || echo "0")
    max_deployed=$(echo "$proxy" | jq -r '[.deployments[]? | select(.state=="deployed") | (.revision|tonumber)] | if length==0 then 0 else max end // 0')

    if [ "$dep_len" -eq 0 ]; then
        not_deployed=$(( not_deployed + 1 ))
    else
        deployed=$(( deployed + 1 ))
    fi
    if [ -n "$latest_int" ] && [ "$latest_int" -ne 0 ] && [ "$max_deployed" -ne 0 ] && [ $(( latest_int - max_deployed )) -gt "$STALE_REVISION_THRESHOLD" ]; then
        stale=$(( stale + 1 ))
    fi
done <<< "$(jq -c '.proxies[]?' proxy_discovery.json)"

while IFS= read -r env; do
    [ -z "$env" ] && continue
    dep_len=$(echo "$env" | jq '[.deployments[]? | select(.state=="deployed")] | length')
    if [ "$dep_len" -eq 0 ]; then
        empty_envs=$(( empty_envs + 1 ))
    fi
done <<< "$(jq -c '.environments[]?' proxy_discovery.json)"

echo "Summary totals: $total proxy(ies), $deployed deployed, $not_deployed not-deployed, $stale stale, $empty_envs environment(s) with zero deployments."

verdict="HEALTHY"
severity=0
if [ "$not_deployed" -gt 0 ] || [ "$stale" -gt 0 ]; then
    verdict="AT_RISK"
    severity=3
fi
if [ "$empty_envs" -gt 0 ]; then
    verdict="AT_RISK"
    severity=4
fi

jq -n \
    --arg org "$APIGEE_ORG" \
    --arg project "$GCP_PROJECT_ID" \
    --argjson total "$total" \
    --argjson deployed "$deployed" \
    --argjson not_deployed "$not_deployed" \
    --argjson stale "$stale" \
    --argjson environments "$env_total" \
    --argjson empty_environments "$empty_envs" \
    --arg verdict "$verdict" \
    --argjson severity "$severity" \
    '{organization:$org, project:$project, proxies_total:$total, proxies_deployed:$deployed, proxies_not_deployed:$not_deployed, proxies_stale:$stale, environments_total:$environments, environments_empty:$empty_environments, verdict:$verdict, severity:$severity}' > "$REPORT_FILE"

if [ "$not_deployed" -gt 0 ] || [ "$stale" -gt 0 ] || [ "$empty_envs" -gt 0 ]; then
    issue=$(jq -n \
        --arg title "Apigee organization \`$APIGEE_ORG\` has proxy/environment health issues" \
        --arg details "Summary for org '$APIGEE_ORG': $total proxy(ies), $deployed deployed, $not_deployed not deployed, $stale stale revision(s), and $empty_envs environment(s) with zero deployments. Overall verdict: $verdict." \
        --arg severity "$severity" \
        --arg expected "All API proxies should be deployed at the latest revision and all environments should host at least one active deployment" \
        --arg actual "Org '$APIGEE_ORG' has not_deployed=$not_deployed, stale=$stale, empty_envs=$empty_envs; verdict $verdict" \
        --arg next_steps "Review the individual deployment, coverage, and revision findings and remediate each at-risk proxy/environment. See the generated summary at $REPORT_FILE." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Health summary:"
cat "$REPORT_FILE"
echo "Summary issues written to $ISSUES_FILE"
