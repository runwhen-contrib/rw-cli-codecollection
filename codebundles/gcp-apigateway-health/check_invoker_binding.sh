#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Gateway Backend Invoker Permissions
#
# For the deployed ApiConfig of each gateway, extracts every backend
# referenced by x-google-backend.address, resolves the backing Cloud Run
# service, and verifies the gateway's service account holds roles/run.invoker
# on it via run.services.getIamPolicy. Missing invoker bound -> every request
# to that route 403s while gateway and Cloud Run both report healthy (most
# common API Gateway failure, sev 2).
#
# The reusable logic lives in apigateway_common.sh (check_gateway_invoker_bindings)
# so it can be lifted later for Cloud Run service-account IAM PR review.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh
#
# OUTPUTS:
#   invoker_binding_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. ./apigateway_common.sh

ISSUES_FILE="invoker_binding_issues.json"
issues='[]'

echo "Checking gateway backend invoker permissions in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

gw_count=$(echo "$inventory" | jq '.gateways | length')
[ "$gw_count" -eq 0 ] && { echo "No gateways to check for invoker bindings."; apigw_write_issues "$ISSUES_FILE" "$issues"; exit 0; }

echo "$inventory" | jq -c '.gateways[]' | while IFS= read -r gw; do
    gw_id=$(echo "$gw" | jq -r '.gatewayId')
    loc=$(echo "$gw" | jq -r '.location')
    api_cfg=$(echo "$gw" | jq -r '.apiConfig // ""')
    cfg_id=$(echo "$api_cfg" | awk -F/ '{print $NF}')
    api_id=$(echo "$api_cfg" | awk -F/ '{print $(NF-1)}')
    [ -z "$api_id" ] || [ "$api_id" = "null" ] && api_id=$(echo "$api_cfg" | awk -F/ '{print $7}')
    [ -z "$api_id" ] || [ "$api_id" = "null" ] && api_id=$(echo "$gw" | jq -r '.api // ""')

    if [ -z "$cfg_id" ] || [ -z "$api_id" ]; then
        echo "  Gateway '$gw_id' has no resolvable apiConfig; skipping invoker check."
        continue
    fi

    echo "  Checking invoker bindings for gateway '$gw_id' on config '$cfg_id' of api '$api_id'"
    gw_issues=$(check_gateway_invoker_bindings "$gw_id" "$cfg_id" "$api_id" "$loc")
    if [ "$(echo "$gw_issues" | jq length)" -gt 0 ]; then
        issues=$(echo "$issues" | jq --argjson i "$gw_issues" '. += $i')
    fi
done

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Invoker binding check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
