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

# This SLX is scoped to a project, not to an individual resource, so issues are
# raised per PROBLEM CLASS rather than per resource: one issue for "ApiConfigs
# are not ACTIVE", listing every affected config in its details, rather than one
# issue per config.
#
# Two reasons. Issue identity is the title, so a per-resource title makes the
# same recurring problem look like a different issue each time the affected set
# changes -- and the resource state itself (CREATING -> FAILED) would rewrite the
# title mid-incident. And a project-scoped SLX has no per-resource identity to
# attach an issue to, so N resources with one fault is one occurrence of that
# fault, not N faults.
#
# Resource ids, states and counts all live in details/actual, which are free to
# vary between runs.

# ApiConfig in a FAILED state -> deploy never took effect (bad spec/backend addr)
config_count=$(echo "$inventory" | jq '[.configs[] | select((.state // "") != "ACTIVE")] | length')
if [ "$config_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" --arg proj "$GCP_PROJECT_ID" '
        ([ $inv.configs[] | select((.state // "") != "ACTIVE")
           | "  - `" + .configId + "` (api `" + .api + "`): state " + .state ] | join("\n")) as $list
        | ([ $inv.configs[] | select((.state // "") != "ACTIVE") ] | length) as $n
        | . + [{
            title: "API Gateway ApiConfigs are not in ACTIVE state",
            details: ("The following ApiConfig(s) in project `" + $proj + "` are not ACTIVE:\n\n" + $list
                      + "\n\nA FAILED ApiConfig means the deployment never took effect, usually due to a malformed OpenAPI spec or an invalid backend address."),
            severity: 2,
            expected: "All ApiConfigs should be in ACTIVE state so the deployment takes effect",
            actual: (($n | tostring) + " ApiConfig(s) are not in ACTIVE state"),
            next_steps: ("Inspect each ApiConfig listed above for OpenAPI spec errors: gcloud api-gateway api-configs describe <config-id> --api=<api-id> --project=" + $proj + ". Fix the OpenAPI spec / backend address and redeploy the ApiConfig.")
        }]')
fi

# Gateway in a FAILED (or non-ACTIVE critical) state -> broken regional deploy
gw_count=$(echo "$inventory" | jq '[.gateways[] | select((.state // "") != "ACTIVE")] | length')
if [ "$gw_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" --arg proj "$GCP_PROJECT_ID" '
        ([ $inv.gateways[] | select((.state // "") != "ACTIVE")
           | "  - `" + .gatewayId + "` (region `" + .location + "`): state " + .state ] | join("\n")) as $list
        | ([ $inv.gateways[] | select((.state // "") != "ACTIVE") ] | length) as $n
        | . + [{
            title: "API Gateway Gateways are not in ACTIVE state",
            details: ("The following Gateway(s) in project `" + $proj + "` are not ACTIVE, indicating a broken regional deployment:\n\n" + $list),
            severity: 2,
            expected: "All Gateways should be in ACTIVE state so traffic is served",
            actual: (($n | tostring) + " Gateway(s) are not in ACTIVE state"),
            next_steps: ("Review each failing gateway listed above: gcloud api-gateway gateways describe <gateway-id> --location=<region> --project=" + $proj + ". Check recent operations for the gateway and redeploy or update it as needed.")
        }]')
fi

# Api resource non-ACTIVE (informational about the api itself)
api_count=$(echo "$inventory" | jq '[.apis[] | select((.state // "") != "ACTIVE")] | length')
if [ "$api_count" -gt 0 ]; then
    issues=$(echo "$issues" | jq --argjson inv "$inventory" --arg proj "$GCP_PROJECT_ID" '
        ([ $inv.apis[] | select((.state // "") != "ACTIVE")
           | "  - `" + .apiId + "`: state " + .state ] | join("\n")) as $list
        | ([ $inv.apis[] | select((.state // "") != "ACTIVE") ] | length) as $n
        | . + [{
            title: "API Gateway Apis are not in ACTIVE state",
            details: ("The following Api(s) in project `" + $proj + "` are not ACTIVE:\n\n" + $list),
            severity: 3,
            expected: "All Apis should be in ACTIVE state",
            actual: (($n | tostring) + " Api(s) are not in ACTIVE state"),
            next_steps: ("Review each Api listed above: gcloud api-gateway apis describe <api-id> --project=" + $proj + ".")
        }]')
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Resource state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
