#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verify API Gateway Managed Service is Enabled
#
# Confirms the API's managed Service Infrastructure service (named
# <api-id>-<hash>.apigateway.<project>.cloud.goog) is enabled on the project
# via gcloud services list --enabled. If it is not, every request fails at the
# edge with 'API not enabled' while the gateway resource itself looks healthy
# (total outage, sev 2).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh
#
# OUTPUTS:
#   managed_service_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. ./apigateway_common.sh

ISSUES_FILE="managed_service_issues.json"
issues='[]'
suffix=".apigateway.$GCP_PROJECT_ID.cloud.goog"

echo "Checking API Gateway managed services are enabled in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

api_count=$(echo "$inventory" | jq '.apis | length')
[ "$api_count" -eq 0 ] && { echo "No apis to check for managed service."; apigw_write_issues "$ISSUES_FILE" "$issues"; exit 0; }

enabled_services=$(gcloud services list --enabled --project="$GCP_PROJECT_ID" \
    --format="value(config.name)" 2>/dev/null || echo "")

# Process substitution, not `... | while` -- see check_invoker_binding.sh.
while IFS= read -r api; do
    api_id=$(echo "$api" | jq -r '.apiId')

    # The managed service name always ends with <api-id>-<hash>.apigateway.<project>.cloud.goog
    # The hash is computed by Service Infrastructure and cannot be derived, so
    # match enabled services by the api-id prefix + project suffix.
    matched=$(echo "$enabled_services" | grep -E "^${api_id}-.*${suffix}$" || true)

    if [ -z "$matched" ]; then
        issue=$(jq -n \
            --arg title "Managed service for Api \`$api_id\` is not enabled" \
            --arg details "No enabled Service Infrastructure service matching '<api-id>-*$suffix' was found for api '$api_id' in project '$GCP_PROJECT_ID'. When the managed service is disabled, every request routed by the gateway fails at the edge with 'API not enabled' while the gateway resource itself reports healthy." \
            --arg severity "2" \
            --arg expected "The API's managed Service Infrastructure service should be enabled on the project" \
            --arg actual "No enabled managed service found for api '$api_id'" \
            --arg next_steps "Enable the managed service and confirm the expected service name with: gcloud services list --enabled --project=$GCP_PROJECT_ID | grep '$suffix'. Then enable it if needed. If the gateway is recently created, allow a few minutes for Service Infrastructure to provision the managed service." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
    else
        echo "  Api '$api_id' managed service enabled: $(echo "$matched" | head -n1)"
    fi
done < <(echo "$inventory" | jq -c '.apis[]')

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Managed service check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
