#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check GCP API Gateway Config Drift
#
# For each Gateway, verifies gateway.apiConfig points at the newest ACTIVE
# ApiConfig for its API. Flags silent drift where a new ApiConfig exists but
# the Gateway was never updated: gateway ACTIVE, config ACTIVE, all status
# checks pass, yet stale routes are served in production (sev 2).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh
#
# OUTPUTS:
#   config_drift_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. ./apigateway_common.sh

ISSUES_FILE="config_drift_issues.json"
issues='[]'
drifted=''
remediation=''

echo "Checking API Gateway config drift in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

gw_count=$(echo "$inventory" | jq '.gateways | length')
[ "$gw_count" -eq 0 ] && { echo "No gateways to check for drift."; apigw_write_issues "$ISSUES_FILE" "$issues"; exit 0; }

# Build a map from api -> newest ACTIVE config createTime/name
newest_per_api=$(echo "$inventory" | jq '
    .configs
    | map(select(.state == "ACTIVE"))
    | group_by(.api)
    | map({
        api: .[0].api,
        newest: (sort_by(.createTime) | .[-1])
      })
    | map({key:.api, value:.newest})
    | from_entries')

# Process substitution, not `... | while` -- see check_invoker_binding.sh.
while IFS= read -r gw; do
    gw_id=$(echo "$gw" | jq -r '.gatewayId')
    loc=$(echo "$gw" | jq -r '.location')
    current_cfg=$(echo "$gw" | jq -r '.apiConfig // ""')

    # Older gcloud versions populate apiConfig without the full path; fall back.
    cfg_id=$(apigw_config_id_from_path "$current_cfg")
    if [ -z "$cfg_id" ] || [ "$cfg_id" = "null" ]; then
        # Try to read from the gateway describe output
        current_cfg=$(gcloud api-gateway gateways describe "$gw_id" --location="$loc" \
            --project="$GCP_PROJECT_ID" --format="value(apiConfig)" 2>/dev/null || echo "")
        cfg_id=$(apigw_config_id_from_path "$current_cfg")
    fi

    if [ -z "$cfg_id" ]; then
        continue
    fi

    api_id=$(apigw_api_id_from_path "$current_cfg")
    [ -z "$api_id" ] && api_id=$(echo "$gw" | jq -r '.api // ""')

    newest_name=$(echo "$newest_per_api" | jq -r --arg api "$api_id" '.[$api].name // ""')
    newest_id=$(echo "$newest_name" | awk -F/ '{print $NF}')

    if [ -z "$newest_id" ] || [ -z "$api_id" ]; then
        continue
    fi

    # Accumulate rather than emit per gateway -- see the issue-scoping note in
    # check_states.sh. The newest config id in particular must stay out of the
    # title: it changes every time a new config is deployed while the drift
    # persists, which would rewrite the title of an unresolved issue.
    if [ "$cfg_id" != "$newest_id" ]; then
        drifted="${drifted}  - \`$gw_id\` (region \`$loc\`, api \`$api_id\`): pinned to \`$cfg_id\`, newest ACTIVE is \`$newest_id\`"$'\n'
        remediation="${remediation}  gcloud api-gateway gateways update $gw_id --api-config=$newest_id --location=$loc --project=$GCP_PROJECT_ID"$'\n'
    fi
done < <(echo "$inventory" | jq -c '.gateways[]')

if [ -n "$drifted" ]; then
    n=$(printf '%s' "$drifted" | grep -c .)
    issue=$(jq -n \
        --arg title "API Gateway Gateways are pinned to a stale ApiConfig" \
        --arg details "The following Gateway(s) in project '$GCP_PROJECT_ID' are pointed at an ApiConfig older than the newest ACTIVE one for their API:"$'\n\n'"$drifted"$'\n'"The gateway, config and all status checks report healthy, yet stale routes are served in production." \
        --arg severity "2" \
        --arg expected "Each Gateway should point at the newest ACTIVE ApiConfig for its API" \
        --arg actual "$n Gateway(s) are pinned to a stale ApiConfig" \
        --arg next_steps "Update each gateway listed above to its newest config, then verify the new routes are served before promoting more traffic:"$'\n'"$remediation" \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Config drift check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
