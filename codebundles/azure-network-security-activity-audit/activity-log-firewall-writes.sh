#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
# Optional:
#   AZURE_RESOURCE_GROUP, ACTIVITY_LOOKBACK_HOURS, ACTIVITY_LOG_MAX_EVENTS
# Writes:
#   firewall_activity_events.json
#   firewall_writes_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

OUTPUT_ISSUES="firewall_writes_issues.json"
OUTPUT_EVENTS="firewall_activity_events.json"
issues_json='[]'

ACTIVITY_LOOKBACK_HOURS="${ACTIVITY_LOOKBACK_HOURS:-168}"
ACTIVITY_LOG_MAX_EVENTS="${ACTIVITY_LOG_MAX_EVENTS:-500}"

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "$ACTIVITY_LOOKBACK_HOURS hours ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "Querying Azure Activity Log for Azure Firewall / policy mutations from $start_time to $end_time"

az account set --subscription "$AZURE_SUBSCRIPTION_ID" || {
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Cannot Set Azure Subscription Context" \
    --arg d "az account set failed." \
    --arg s "4" \
    --arg n "Run az login or verify service principal" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_EVENTS"
  exit 0
}

extra_args=()
if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
  extra_args+=(--resource-group "$AZURE_RESOURCE_GROUP")
fi

if ! raw=$(az monitor activity-log list \
      --subscription "$AZURE_SUBSCRIPTION_ID" \
      --start-time "$start_time" \
      --end-time "$end_time" \
      "${extra_args[@]}" \
      --max-events "$ACTIVITY_LOG_MAX_EVENTS" \
      -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Activity Log Query Failed (Firewall Scope)" \
    --arg d "$err_msg" \
    --arg s "4" \
    --arg n "Ensure Reader on subscription and Activity Log access" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_EVENTS"
  exit 0
fi
rm -f err.log

filtered=$(echo "$raw" | jq '[.[] | select(.operationName.value != null)
  | select(.operationName.value | test("azureFirewalls|firewallPolicies|ruleCollection"; "i"))
  | select(.operationName.value | test("/write|/delete|/action"; "i"))
  | {
      eventTimestamp,
      caller,
      operationName: .operationName.value,
      status: .status.value,
      statusCode: (.properties.statusCode // .httpRequest.statusCode // "N/A"),
      resourceId,
      resourceGroupName,
      correlationId,
      claims: (.claims // {}),
      subStatus: .subStatus.localizedValue
    }]')

echo "$filtered" > "$OUTPUT_EVENTS"
count=$(echo "$filtered" | jq 'length')
echo "Found $count Azure Firewall / policy related events (max-events=$ACTIVITY_LOG_MAX_EVENTS)."

if [[ "$count" -ge "$ACTIVITY_LOG_MAX_EVENTS" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Activity Log Result Set May Be Truncated (Firewall Query)" \
    --arg d "Returned $count events (equals max-events cap). Narrow lookback or resource group scope." \
    --arg s "2" \
    --arg n "Reduce ACTIVITY_LOOKBACK_HOURS or set AZURE_RESOURCE_GROUP" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

failed=$(echo "$filtered" | jq '[.[] | select(.status == "Failed")] | length')
if [[ "$failed" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed Firewall / Policy Operations in Window" \
    --arg d "$(echo "$filtered" | jq -c '[.[] | select(.status == "Failed")]')" \
    --arg s "3" \
    --arg n "Review failed operations on Azure Firewall or Firewall Policy resources" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Firewall activity query complete."
