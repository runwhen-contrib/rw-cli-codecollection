#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check GCP API Gateway Resource States
#
# Flags any Api, ApiConfig or Gateway in a FAILED (or otherwise non-ACTIVE
# critical) state. An ApiConfig FAILED indicates a bad OpenAPI spec or invalid
# backend address where the deploy never took effect (sev 2). A Gateway FAILED
# indicates a broken regional deployment (sev 2). Backend health handoff
# happens elsewhere (see check_backends.sh).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh
#
# OUTPUTS:
#   resource_state_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. ./apigateway_common.sh

ISSUES_FILE="resource_state_issues.json"
issues='[]'

echo "Checking API Gateway resource states in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

# ApiConfig in a FAILED state -> deploy never took effect (bad spec/backend addr)
config_count=$(echo "$inventory" | jq '[.configs[] | select((.state // "") != "ACTIVE")] | length')
if [ "$config_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" '
        [ .[] ] + [ $inv.configs[] | select((.state // "") != "ACTIVE") |
        {
            title: ("ApiConfig `" + .configId + "` for api `" + .api + "` is in state `" + .state + "`"),
            details: ("ApiConfig '"'"'`" + .configId + "`'"'"' of api '"'"'`" + .api + "`'"'"' in project '"'"'$GCP_PROJECT_ID'"'"' is not ACTIVE (state: `" + .state + "`). A FAILED ApiConfig means the deployment never took effect, usually due to a malformed OpenAPI spec or an invalid backend address."),
            severity: 2,
            expected: "All ApiConfigs should be in ACTIVE state so the deployment takes effect",
            actual: ("ApiConfig `" + .configId + "` is in state `" + .state + "`"),
            next_steps: "Inspect the ApiConfig for OpenAPI spec errors: gcloud api-gateway api-configs describe " + .configId + " --api=" + .api + " --project=$GCP_PROJECT_ID. Fix the OpenAPI spec / backend address and redeploy the ApiConfig."
        }]')

fi

# Gateway in a FAILED (or non-ACTIVE critical) state -> broken regional deploy
gw_count=$(echo "$inventory" | jq '[.gateways[] | select((.state // "") != "ACTIVE")] | length')
if [ "$gw_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" '
        [ .[] ] + [ $inv.gateways[] | select((.state // "") != "ACTIVE") |
        {
            title: ("Gateway `" + .gatewayId + "` in region `" + .location + "` is in state `" + .state + "`"),
            details: ("Gateway '"'"'`" + .gatewayId + "`'"'"' in region '"'"'`" + .location + "`'"'"' of project '"'"'$GCP_PROJECT_ID'"'"' is not ACTIVE (state: `" + .state + "`), indicating a broken regional deployment."),
            severity: 2,
            expected: "All Gateways should be in ACTIVE state so traffic is served",
            actual: ("Gateway `" + .gatewayId + "` is in state `" + .state + "`"),
            next_steps: "Review the failing gateway deployment: gcloud api-gateway gateways describe " + .gatewayId + " --location=" + .location + " --project=$GCP_PROJECT_ID. Check recent operations for the gateway and redeploy or update it as needed."
        }]')
fi

# Api resource non-ACTIVE (informational about the api itself)
api_count=$(echo "$inventory" | jq '[.apis[] | select((.state // "") != "ACTIVE")] | length')
if [ "$api_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" '
        [ .[] ] + [ $inv.apis[] | select((.state // "") != "ACTIVE") |
        {
            title: ("Api `" + .apiId + "` is in state `" + .state + "`"),
            details: ("Api '"'"'`" + .apiId + "`'"'"' in project '"'"'$GCP_PROJECT_ID'"'"' is not ACTIVE (state: `" + .state + "`)."),
            severity: 3,
            expected: "All Apis should be in ACTIVE state",
            actual: ("Api `" + .apiId + "` is in state `" + .state + "`"),
            next_steps: "Review the Api resource: gcloud api-gateway apis describe " + .apiId + " --project=$GCP_PROJECT_ID."
        }]')
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Resource state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
