#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover GCP API Gateway Apis, Configs and Gateways
#
# Lists all Api, ApiConfig and Gateway resources in the project plus their
# states using the gcloud api-gateway CLI, then dumps a JSON inventory
# (names, states, regions, and each gateway's linked apiConfig) consumed by the
# other tasks. Discovery is dynamic from the project. If discovery returns
# nothing usable, the script falls back to the explicit GCP_PROJECT_ID (and
# optional API_NAME / API_CONFIG_NAME / GATEWAY_NAME / GCP_REGIONS) config so
# the bundle still runs.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   API_NAME, API_CONFIG_NAME, GATEWAY_NAME, GCP_REGIONS
#
# OUTPUTS:
#   apigateway_inventory.json         - merged inventory of apis/configs/gateways
#   apigateway_discovery_issues.json - JSON array of issues (usually empty)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

. ./apigateway_common.sh

INVENTORY_FILE="apigateway_inventory.json"
ISSUES_FILE="apigateway_discovery_issues.json"
issues_json='[]'

echo "Discovering API Gateway resources in project: $GCP_PROJECT_ID"

apis=$(gcloud api-gateway apis list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
configs=$(gcloud api-gateway api-configs list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
gateways=$(gcloud api-gateway gateways list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

# Apply explicit config filters (configProvided path) when supplied.
if [ -n "$API_NAME" ]; then
    apis=$(echo "$apis" | jq --arg a "$API_NAME" '[.[] | select((.name | split("/") | .[-1]) == $a)]')
    configs=$(echo "$configs" | jq --arg a "$API_NAME" '[.[] | select((.name | split("/") | .[5]) == $a)]')
fi
if [ -n "$API_CONFIG_NAME" ]; then
    configs=$(echo "$configs" | jq --arg c "$API_CONFIG_NAME" '[.[] | select((.name | split("/") | .[-1]) == $c)]')
fi
if [ -n "$GATEWAY_NAME" ]; then
    gateways=$(echo "$gateways" | jq --arg g "$GATEWAY_NAME" '[.[] | select((.name | split("/") | .[-1]) == $g)]')
fi

# Normalize apis
# managedService is the Service Infrastructure service backing the Api
# (<api-id>-<hash>.apigateway.<project>.cloud.goog). It is the only thing that
# scopes serviceruntime.googleapis.com/api/* metrics to this bundle's gateways
# rather than to every Google API call in the project, so it must be captured.
apis_norm=$(echo "$apis" | jq --arg project "$GCP_PROJECT_ID" '
    [.[] | {
        name: (.name // ""),
        apiId: (.name | split("/") | .[-1]),
        displayName: (.displayName // ""),
        state: (.state // "UNKNOWN"),
        managedService: (.managedService // ""),
        createTime: (.createTime // "")
    }]')

# Normalize api-configs
# An ApiConfig name is projects/<p>/locations/global/apis/<api>/configs/<cfg>,
# so the api id is segment 5 -- segment 7 is the config id itself.
configs_norm=$(echo "$configs" | jq '
    [.[] | {
        name: (.name // ""),
        configId: (.name | split("/") | .[-1]),
        api: (.name | split("/") | (if length > 5 then .[5] else "" end)),
        displayName: (.displayName // ""),
        state: (.state // "UNKNOWN"),
        createTime: (.createTime // "")
    }]')

# Normalize gateways; for each gateway also describe it to grab its service
# account and authoritative apiConfig when the list output omits it.
gateways_norm="[]"
if [ "$(echo "$gateways" | jq length)" -gt 0 ]; then
    # The Gateway resource has no `location`/`locations` field -- the region
    # lives only inside `.name`
    # (projects/<p>/locations/<region>/gateways/<id>), so parse it from there.
    # Likewise the api id comes from the apiConfig path
    # (projects/<p>/locations/global/apis/<api>/configs/<cfg>), where the api is
    # segment 6; segment 7 is the literal string "configs".
    gateways_norm=$(echo "$gateways" | jq '
        [.[] | {
            name: (.name // ""),
            gatewayId: (.name | split("/") | .[-1]),
            displayName: (.displayName // ""),
            state: (.state // "UNKNOWN"),
            location: ((.name // "") | split("/") | (if length > 3 then .[3] else "" end)),
            apiConfig: (.apiConfig // ""),
            api: ((.apiConfig // "") | split("/") | (if length > 5 then .[5] else "" end)),
            createTime: (.createTime // "")
        }]')
    # Enrich with describe (authoritative apiConfig) and with the ApiConfig's
    # gatewayServiceAccount -- the identity the gateway uses to reach backends.
    # That field is on the ApiConfig; the Gateway has no `defaults` field.
    gateways_norm=$(while IFS= read -r gw; do
        gw_id=$(echo "$gw" | jq -r '.gatewayId')
        loc=$(echo "$gw" | jq -r '.location')
        detail=$(gcloud api-gateway gateways describe "$gw_id" --location="$loc" \
            --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
        api_cfg=$(echo "$detail" | jq -r '.apiConfig // ""')
        [ -z "$api_cfg" ] && api_cfg=$(echo "$gw" | jq -r '.apiConfig // ""')

        cfg_id=$(apigw_config_id_from_path "$api_cfg")
        api_id=$(apigw_api_id_from_path "$api_cfg")
        [ -z "$api_id" ] && api_id=$(echo "$gw" | jq -r '.api // ""')

        sa=""
        if [ -n "$cfg_id" ] && [ -n "$api_id" ]; then
            sa=$(apigw_get_config_service_account "$cfg_id" "$api_id")
        fi

        echo "$gw" | jq --arg cfg "$api_cfg" --arg api "$api_id" --arg sa "$sa" \
            '.apiConfig=$cfg | .api=$api | .serviceAccount=$sa'
    done < <(echo "$gateways_norm" | jq -c '.[]') | jq -s '.')
fi

# Determine regions from gateways (or explicit GCP_REGIONS).
regions="[]"
if [ -n "$GCP_REGIONS" ]; then
    regions=$(echo "$GCP_REGIONS" | tr ',' '\n' | jq -R . | jq -s '.')
else
    regions=$(echo "$gateways_norm" | jq '[.[].location] | unique')
fi

inventory=$(jq -n \
    --arg project "$GCP_PROJECT_ID" \
    --argjson apis "$apis_norm" \
    --argjson configs "$configs_norm" \
    --argjson gateways "$gateways_norm" \
    --argjson regions "$regions" \
    '{project:$project, apis:$apis, configs:$configs, gateways:$gateways, regions:$regions}')

echo "$inventory" > "$INVENTORY_FILE"

api_count=$(echo "$inventory" | jq '.apis | length')
config_count=$(echo "$inventory" | jq '.configs | length')
gateway_count=$(echo "$inventory" | jq '.gateways | length')

if [ "$api_count" = "0" ] && [ "$config_count" = "0" ] && [ "$gateway_count" = "0" ]; then
    echo "No API Gateway resources discovered for project $GCP_PROJECT_ID."
    echo "[]" > "$ISSUES_FILE"
else
    echo "[]" > "$ISSUES_FILE"
fi

echo "Discovery complete: $api_count api(s), $config_count config(s), $gateway_count gateway(s)."
echo "Inventory written to $INVENTORY_FILE"
