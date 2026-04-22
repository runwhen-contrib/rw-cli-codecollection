#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lightweight combined dimensions for SLI (single pass per account).
# Prints one JSON object to stdout: dimensions + aggregate (0-1).
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

empty_out() {
  jq -n '{dimensions:{resource_health:0,api_consistency:0,backup:0,network:0,private_endpoints:0,diagnostics:0,activity:0},aggregate:0}'
}

subscription="$(cosmosdb_resolve_subscription)"
if [[ -z "$subscription" ]]; then
  empty_out
  exit 0
fi

if ! az account set --subscription "$subscription" 2>/dev/null; then
  empty_out
  exit 0
fi

LOOKBACK_HOURS="${ACTIVITY_LOG_LOOKBACK_HOURS:-168}"
OFFSET="${LOOKBACK_HOURS}h"
COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
mapfile -t accounts < <(cosmosdb_account_names "$subscription" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

if [[ ${#accounts[@]} -eq 0 || -z "${accounts[0]:-}" ]]; then
  empty_out
  exit 0
fi

sum_rh=0 sum_api=0 sum_bu=0 sum_net=0 sum_pe=0 sum_diag=0 sum_act=0
n=0

for acct in "${accounts[@]}"; do
  [[ -z "$acct" ]] && continue
  n=$((n + 1))

  url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.DocumentDB/databaseAccounts/${acct}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"
  rh=0
  if health=$(az rest --method get --url "$url" -o json 2>/dev/null); then
    t=$(echo "$health" | jq -r '.properties.title // ""')
    [[ "$t" == "Available" ]] && rh=1 || rh=0
  fi

  if ! detail=$(az cosmosdb show -g "$AZURE_RESOURCE_GROUP" -n "$acct" --subscription "$subscription" -o json 2>/dev/null); then
    sum_rh=$((sum_rh + rh))
    continue
  fi

  api=1
  defcons=$(echo "$detail" | jq -r '.consistencyPolicy.defaultConsistencyLevel // ""')
  [[ "$defcons" == "Eventual" ]] && api=0
  mwl=$(echo "$detail" | jq -r '.enableMultipleWriteLocations // false')
  loc_count=$(echo "$detail" | jq '[.locations[]?] | length')
  [[ "$mwl" == "true" && "${loc_count:-0}" -lt 2 ]] && api=0
  dk=$(echo "$detail" | jq -r '.disableKeyBasedMetadataWriteAccess // false')
  [[ "$dk" != "true" ]] && api=0

  bu=1
  btype=$(echo "$detail" | jq -r '.backupPolicy.type // "unknown"')
  if [[ "$btype" == "Periodic" ]]; then
    ret_h=$(echo "$detail" | jq -r '(.backupPolicy.periodicModeProperties.backupRetentionIntervalInHours // 0)')
    [[ "${ret_h:-0}" -lt 8 ]] && bu=0
  elif [[ "$btype" != "Continuous" ]]; then
    bu=0
  fi

  net=1
  pub=$(echo "$detail" | jq -r '.publicNetworkAccess // "Enabled"')
  ip_count=$(echo "$detail" | jq '[.ipRules[]?] | length')
  open_ip=$(echo "$detail" | jq '[.ipRules[]? | select(.ipAddressOrRange == "0.0.0.0")] | length')
  [[ "${open_ip:-0}" -gt 0 ]] && net=0
  if [[ "$pub" == "Enabled" && "${ip_count:-0}" -eq 0 ]]; then
    pe_count=$(echo "$detail" | jq '[.privateEndpointConnections[]?] | length')
    [[ "${pe_count:-0}" -eq 0 ]] && net=0
  fi

  pe=1
  if [[ "$pub" != "Enabled" ]]; then
    pe_n=$(echo "$detail" | jq '[.privateEndpointConnections[]?] | length')
    if [[ "${pe_n:-0}" -eq 0 ]]; then
      pe=0
    else
      bad_pe=$(echo "$detail" | jq '[.privateEndpointConnections[]? | select((.privateLinkServiceConnectionState.status // "") != "Approved")] | length')
      [[ "${bad_pe:-0}" -gt 0 ]] && pe=0
    fi
  fi

  diag=0
  rid="$(cosmosdb_account_resource_id "$subscription" "$AZURE_RESOURCE_GROUP" "$acct")"
  if settings=$(az monitor diagnostic-settings list --resource "$rid" --subscription "$subscription" -o json 2>/dev/null); then
    dn=$(echo "$settings" | jq 'if type == "array" then length else [.value[]?] | length end')
    [[ "${dn:-0}" -gt 0 ]] && diag=1
  fi

  act=1
  if log_json=$(az monitor activity-log list --resource-id "$rid" --offset "$OFFSET" --max-events 50 --subscription "$subscription" -o json 2>/dev/null); then
    acount=$(echo "$log_json" | jq '[.[] | select(
      .category.value == "Administrative" or .category.localizedValue == "Administrative" or .category == "Administrative"
    )] | length')
    [[ "${acount:-0}" -gt 0 ]] && act=0
  fi

  sum_rh=$((sum_rh + rh))
  sum_api=$((sum_api + api))
  sum_bu=$((sum_bu + bu))
  sum_net=$((sum_net + net))
  sum_pe=$((sum_pe + pe))
  sum_diag=$((sum_diag + diag))
  sum_act=$((sum_act + act))
done

if [[ "$n" -eq 0 ]]; then
  empty_out
  exit 0
fi

jq -n \
  --argjson sum_rh "$sum_rh" \
  --argjson sum_api "$sum_api" \
  --argjson sum_bu "$sum_bu" \
  --argjson sum_net "$sum_net" \
  --argjson sum_pe "$sum_pe" \
  --argjson sum_diag "$sum_diag" \
  --argjson sum_act "$sum_act" \
  --argjson n "$n" \
  '
  ($sum_rh/$n) as $rh |
  ($sum_api/$n) as $api |
  ($sum_bu/$n) as $bu |
  ($sum_net/$n) as $net |
  ($sum_pe/$n) as $pe |
  ($sum_diag/$n) as $diag |
  ($sum_act/$n) as $act |
  (($rh + $api + $bu + $net + $pe + $diag + $act) / 7) as $agg |
  {dimensions:{resource_health:$rh, api_consistency:$api, backup:$bu, network:$net, private_endpoints:$pe, diagnostics:$diag, activity:$act}, aggregate:$agg}
  '
