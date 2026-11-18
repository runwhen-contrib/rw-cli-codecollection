#!/usr/bin/env bash
# Merges prior JSON outputs into a per-subnet validation matrix and optional consolidated issues list.
# Writes subnet_summary_issues.json and subnet_summary_matrix.json
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_FILE="subnet_summary_issues.json"
MATRIX_JSON="subnet_summary_matrix.json"

merge_issue_files() {
  local files=()
  for f in subnet_discover_issues.json subnet_effective_nsg_issues.json subnet_route_issues.json subnet_probe_issues.json; do
    [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo '[]'
    return
  fi
  jq -s 'add' "${files[@]}" 2>/dev/null || echo '[]'
}

merged_issues=$(merge_issue_files)
echo "$merged_issues" > "$OUTPUT_FILE"

disc_json='[]'
rt_json='[]'
probe_json='[]'
if [ -f subnet_discovery.json ]; then
  disc_json=$(cat subnet_discovery.json)
fi
if [ -f subnet_route_summary.json ]; then
  rt_json=$(cat subnet_route_summary.json)
fi
if [ -f subnet_probe_results.json ]; then
  probe_json=$(cat subnet_probe_results.json)
fi

matrix=$(jq -n \
  --arg vnet "$VNET_NAME" \
  --arg rg "$AZURE_RESOURCE_GROUP" \
  --arg sub "$AZURE_SUBSCRIPTION_ID" \
  --argjson discovery "$disc_json" \
  --argjson routes "$rt_json" \
  --argjson probes "$probe_json" \
  --argjson issues "$merged_issues" \
  '{
    vnetName: $vnet,
    resourceGroup: $rg,
    subscriptionId: $sub,
    discovery: $discovery,
    routeSummary: $routes,
    probeResults: $probes,
    mergedIssueCount: ($issues | length)
  }')

echo "$matrix" > "$MATRIX_JSON"

echo "Egress validation summary for VNet \`$VNET_NAME\`:"
echo "$matrix" | jq .

issue_count=$(echo "$merged_issues" | jq 'length')
echo "Total merged issues from prior steps: $issue_count"
echo "Matrix written to $MATRIX_JSON; merged issues to $OUTPUT_FILE"
