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
findings='[]'

echo "Checking gateway backend invoker permissions in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

gw_count=$(echo "$inventory" | jq '.gateways | length')
[ "$gw_count" -eq 0 ] && { echo "No gateways to check for invoker bindings."; apigw_write_issues "$ISSUES_FILE" "$issues"; exit 0; }

# NOTE: process substitution, not `... | while`. Piping into the loop would run
# the body in a subshell, so every `issues=` accumulation below would be
# discarded at `done` and this check could never report anything.
while IFS= read -r gw; do
    gw_id=$(echo "$gw" | jq -r '.gatewayId')
    loc=$(echo "$gw" | jq -r '.location')
    api_cfg=$(echo "$gw" | jq -r '.apiConfig // ""')
    cfg_id=$(apigw_config_id_from_path "$api_cfg")
    api_id=$(apigw_api_id_from_path "$api_cfg")
    [ -z "$api_id" ] && api_id=$(echo "$gw" | jq -r '.api // ""')

    if [ -z "$cfg_id" ] || [ -z "$api_id" ]; then
        echo "  Gateway '$gw_id' has no resolvable apiConfig; skipping invoker check."
        continue
    fi

    echo "  Checking invoker bindings for gateway '$gw_id' on config '$cfg_id' of api '$api_id'"
    gw_findings=$(check_gateway_invoker_bindings "$gw_id" "$cfg_id" "$api_id" "$loc")
    if [ "$(echo "$gw_findings" | jq length)" -gt 0 ]; then
        findings=$(echo "$findings" | jq --argjson f "$gw_findings" '. += $f')
    fi
done < <(echo "$inventory" | jq -c '.gateways[]')

# One project-level issue listing every affected gateway/backend pair, rather
# than one issue per pair -- see the issue-scoping note in check_states.sh.
if [ "$(echo "$findings" | jq length)" -gt 0 ]; then
    issue=$(echo "$findings" | jq --arg proj "$GCP_PROJECT_ID" '
        ([ .[] | "  - gateway `" + .gateway + "` (region `" + .location + "`, api `" + .api
                 + "`) -> Cloud Run service `" + .service + "` in `" + .region
                 + "`\n      service account: " + .service_account
                 + "\n      backend: " + .address ] | join("\n")) as $list
        | ([ .[] | "  gcloud run services add-iam-policy-binding " + .service
                 + " --region=" + .region + " --member=serviceAccount:" + .service_account
                 + " --role=roles/run.invoker --project=" + $proj ] | unique | join("\n")) as $fix
        | length as $n
        | {
            title: ("API Gateway service accounts are missing roles/run.invoker in `" + $proj + "`"),
            details: ("The following gateway-to-backend routes in project `" + $proj + "` will return 403 Forbidden, while the gateway and the Cloud Run service both report healthy:\n\n" + $list),
            severity: 2,
            expected: "Every gateway service account should hold roles/run.invoker on the Cloud Run services it calls",
            actual: (($n | tostring) + " gateway-to-backend route(s) lack roles/run.invoker"),
            next_steps: ("Grant invoker on each backing Cloud Run service:\n" + $fix + "\nIf a gateway is not found, check the CLI location matches the deployed region.")
        }')
    issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Invoker binding check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
