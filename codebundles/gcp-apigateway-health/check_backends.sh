#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Detect Dangling and Unreachable Gateway Backends
#
# Flags backends referenced by x-google-backend.address in the deployed config
# that no longer exist (dangling route, sev 3), and surfaces 504s where backend
# latency is near the ESPv2 deadline, indicating a too-short deadline for
# backend cold starts (sev 3). Evidence pointing at the backend should hand off
# to the Cloud Run service health bundle.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   METRIC_LOOKBACK_PERIOD (optional, default 3600s)
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh
#
# OUTPUTS:
#   backend_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
. ./apigateway_common.sh

ISSUES_FILE="backend_issues.json"
issues='[]'
dangling=''
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(apigw_epoch_to_iso8601 "$start_epoch")
end_time=$(apigw_epoch_to_iso8601 "$now_epoch")

echo "Checking gateway backends in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)

# ---- 1) Dangling backends: referenced Cloud Run service no longer exists ----
# Process substitution, not `... | while` -- see check_invoker_binding.sh.
while IFS= read -r gw; do
    gw_id=$(echo "$gw" | jq -r '.gatewayId')
    loc=$(echo "$gw" | jq -r '.location')
    api_cfg=$(echo "$gw" | jq -r '.apiConfig // ""')
    cfg_id=$(apigw_config_id_from_path "$api_cfg")
    api_id=$(apigw_api_id_from_path "$api_cfg")
    [ -z "$api_id" ] && api_id=$(echo "$gw" | jq -r '.api // ""')
    [ -z "$cfg_id" ] && { echo "  Gateway '$gw_id' has no config; skipping backend scan."; continue; }

    spec=$(apigw_get_config_spec "$cfg_id" "$api_id")
    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        # Only Cloud Run backends can be existence-checked here.
        apigw_is_cloudrun_address "$addr" || continue

        # Resolve against the real Cloud Run inventory rather than parsing the
        # URL: service names may contain hyphens and Cloud Run has two URL
        # shapes, so regex extraction silently yields the wrong service.
        resolved=$(apigw_cloudrun_resolve_address "$addr")
        if [ -n "$resolved" ]; then
            continue   # backend resolves to a live service
        fi

        # Accumulate rather than emit per backend -- see the issue-scoping note
        # in check_states.sh.
        host="${addr#*://}"; host="${host%%/*}"
        dangling="${dangling}  - gateway \`$gw_id\` (region \`$loc\`, apiConfig \`$cfg_id\`) -> \`$host\`"$'\n'
    done < <(apigw_extract_backend_addresses "$spec")
done < <(echo "$inventory" | jq -c '.gateways[]')

if [ -n "$dangling" ]; then
    n=$(printf '%s' "$dangling" | grep -c .)
    issue=$(jq -n \
        --arg title "API Gateway Gateways reference dangling Cloud Run backends in \`$GCP_PROJECT_ID\`" \
        --arg details "The following gateway routes in project '$GCP_PROJECT_ID' reference a backend address that no Cloud Run service serves, so requests to them will fail:"$'\n\n'"$dangling" \
        --arg severity "3" \
        --arg expected "Every backend referenced by x-google-backend.address should exist and be reachable" \
        --arg actual "$n gateway route(s) reference a backend that does not exist" \
        --arg next_steps "Update each ApiConfig OpenAPI spec listed above to point at an existing backend, then redeploy and re-pin the gateway. Verify the Cloud Run services are deployed in the expected region: gcloud run services list --project=$GCP_PROJECT_ID." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
fi

# ---- 2) 504s: backend latency near ESPv2 deadline ----
# Previously `if [ -n "$access_token" ]`, which silently dropped the entire 504
# analysis when authentication failed -- no error, no issue, indistinguishable
# from "no 504s found".
if ! access_token=$(apigw_get_access_token); then
    echo "ERROR: could not obtain a GCP access token for the Cloud Monitoring API." >&2
    echo "Cannot query 504 responses; refusing to report a result for a check that never ran." >&2
    exit 1
fi
# 504 responses indicate the gateway/ESPv2 deadline was hit (backend too
# slow / cold start). The specific response_code label is carried by the
# serviceruntime api/request_count metric.
filter="metric.type=\"serviceruntime.googleapis.com/api/request_count\" AND metric.label.response_code=\"504\""
encoded=$(jq -rn --arg v "$filter" '$v|@uri')
url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
total504=$(echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0")
[ -z "$total504" ] && total504=0

if [ "$(echo "$total504" | awk '{printf "%d", $1}')" -gt 0 ]; then
    issue=$(jq -n \
        --arg title "API Gateway is returning 504 Gateway Timeout responses in \`$GCP_PROJECT_ID\`" \
        --arg details "API Gateway (ESPv2) returned 504 responses ($total504) in the last ${METRIC_LOOKBACK_PERIOD} for project '$GCP_PROJECT_ID'. 504s indicate the backend exceeded the gateway's request deadline, typically because a backend cold start exceeded the configured timeout." \
        --arg severity "3" \
        --arg expected "Gateway should not return 504 responses; backends should respond within the configured deadline" \
        --arg actual "$total504 requests returned 504 Gateway Timeout" \
        --arg next_steps "Hand off to the gcp-cloudrun-service-health bundle to diagnose backend cold starts / latency. Verify the Cloud Run min-instances setting and the API Gateway request timeout against backend cold start time." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Backend check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
