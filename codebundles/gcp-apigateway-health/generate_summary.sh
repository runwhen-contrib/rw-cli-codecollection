#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate GCP API Gateway Health Summary
#
# Aggregates findings from all other checks into a consolidated summary per
# gateway (state, config drift, invoker binding, managed service, error rate,
# latency, operations) with an overall verdict, and reports an informational
# (sev 4) finding when an API is deployed to only one region (no failover).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ENABLE_SINGLE_REGION_ADVISORY (optional, default true)
#
# INPUTS (files written by sibling check scripts + discovery):
#   apigateway_inventory.json
#   resource_state_issues.json
#   config_drift_issues.json
#   invoker_binding_issues.json
#   managed_service_issues.json
#   error_rate_issues.json
#   latency_issues.json
#   backend_issues.json
#   operations_issues.json
#
# OUTPUTS:
#   summary_issues.json                     - JSON array (single-region advisories)
#   apigateway_summary_table.txt            - human readable summary table
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENABLE_SINGLE_REGION_ADVISORY:=true}"
. ./apigateway_common.sh

ISSUES_FILE="summary_issues.json"
TABLE_FILE="apigateway_summary_table.txt"
issues='[]'

echo "Generating API Gateway health summary for project: $GCP_PROJECT_ID"

if [ ! -f "apigateway_inventory.json" ]; then
    echo "No discovery data found (apigateway_inventory.json missing). Run the discovery task first."
    apigw_write_issues "$ISSUES_FILE" "$issues"
    echo "No API Gateway inventory discovered." > "$TABLE_FILE"
    exit 0
fi

inventory=$(apigw_load_inventory)
gw_count=$(echo "$inventory" | jq '.gateways | length')

issues_count() {
    local file="$1"
    if [ -f "$file" ]; then
        jq 'length' "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

state_n=$(issues_count "resource_state_issues.json")
drift_n=$(issues_count "config_drift_issues.json")
invoker_n=$(issues_count "invoker_binding_issues.json")
managed_n=$(issues_count "managed_service_issues.json")
error_n=$(issues_count "error_rate_issues.json")
latency_n=$(issues_count "latency_issues.json")
backend_n=$(issues_count "backend_issues.json")
ops_n=$(issues_count "operations_issues.json")

> "$TABLE_FILE"
printf '%-28s %-12s %-8s %-8s %-10s %-10s %-8s %-8s %s\n' \
    "GATEWAY" "REGION" "STATE" "DRIFT" "INVOKER" "MANAGED" "ERROR" "LAT" "VERDICT" >> "$TABLE_FILE"
printf '%s\n' "--------------------------------------------------------------------------------------------------------------" >> "$TABLE_FILE"

if [ "$gw_count" -gt 0 ]; then
    echo "$inventory" | jq -c '.gateways[]' | while IFS= read -r gw; do
        name=$(echo "$gw" | jq -r '.gatewayId')
        loc=$(echo "$gw" | jq -r '.location')
        state=$(echo "$gw" | jq -r '.state // "UNKNOWN"')
        state="OK"; [ "$state_n" -gt 0 ] && state="FAIL"
        drift="OK";  [ "$drift_n" -gt 0 ]  && drift="DRIFT"
        inv="OK";    [ "$invoker_n" -gt 0 ] && inv="MISSING"
        mgd="OK";    [ "$managed_n" -gt 0 ] && mgd="DISABLED"
        err="OK";    [ "$error_n" -gt 0 ]   && err="ELEVATED"
        lat="OK";    [ "$latency_n" -gt 0 ] && lat="HIGH"
        verdict="healthy"
        [ "$state" = "FAIL" ]  && verdict="failed"
        [ "$drift" = "DRIFT" ] && verdict="drift"
        [ "$inv" = "MISSING" ] && verdict="attention"
        [ "$mgd" = "DISABLED" ] && verdict="down"
        [ "$err" = "ELEVATED" ] && verdict="degraded"
        [ "$lat" = "HIGH" ] && verdict="degraded"
        printf '%-28s %-12s %-8s %-8s %-10s %-10s %-8s %-8s %s\n' \
            "$name" "$loc" "$state" "$drift" "$inv" "$mgd" "$err" "$lat" "$verdict" >> "$TABLE_FILE"
    done
else
    echo "No gateways discovered for project $GCP_PROJECT_ID." >> "$TABLE_FILE"
fi

# Per-api region failover advisory (informational, sev 4).
if [ "$ENABLE_SINGLE_REGION_ADVISORY" = "true" ]; then
    single_region_apis=$(echo "$inventory" | jq -r '
        [ .gateways[] | {api: (.api // ""), loc: .location} ]
        | group_by(.api)
        | map({api: .[0].api, regions: ([.[].loc] | unique), count: ([.[].loc] | unique | length)})
        | .[] | select(.api != "" and .count == 1) | "\(.api)|\(.regions[0])"')
    if [ -n "$single_region_apis" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            api="${line%%|*}"
            region="${line##*|}"
            issue=$(jq -n \
                --arg title "Api \`$api\` is deployed in only one region (no failover)" \
                --arg details "API '$api' in project '$GCP_PROJECT_ID' is served by gateways in a single region ('$region') only. If that region becomes unavailable, the API has no active failover and requests will fail." \
                --arg severity "4" \
                --arg expected "APIs should be deployed across more than one region for failover resilience" \
                --arg actual "API '$api' is deployed only in region '$region'" \
                --arg next_steps "Consider deploying an additional gateway region for API '$api' to provide failover. This is an informational/advisory finding." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
        done < <(printf '%s\n' "$single_region_apis")
    fi
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Summary table written to $TABLE_FILE"
cat "$TABLE_FILE"

api_count=$(echo "$inventory" | jq '.apis | length')
echo "API Gateway health summary generated for $api_count api(s), $gw_count gateway(s)."
