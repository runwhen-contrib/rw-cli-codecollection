#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Private Link: when public access is off, require approved private endpoints.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_private_endpoint_issues.json"
echo '[]' > "$OUTPUT_FILE"

subscription="$(cosmosdb_resolve_subscription)"
[[ -z "$subscription" ]] && exit 0
az account set --subscription "$subscription" 2>/dev/null || exit 0

COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
mapfile -t accounts < <(cosmosdb_account_names "$subscription" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")
[[ ${#accounts[@]} -eq 0 || -z "${accounts[0]:-}" ]] && { echo '[]' > "$OUTPUT_FILE"; cat "$OUTPUT_FILE"; exit 0; }

for acct in "${accounts[@]}"; do
  [[ -z "$acct" ]] && continue
  if ! detail=$(az cosmosdb show -g "$AZURE_RESOURCE_GROUP" -n "$acct" --subscription "$subscription" -o json 2>/dev/null); then
    jq --arg t "Cannot read private endpoint configuration for \`${acct}\`" \
      --arg d "az cosmosdb show failed." \
      --argjson s 3 \
      --arg n "Verify Reader access." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  pub=$(echo "$detail" | jq -r '.publicNetworkAccess // "Enabled"')
  if [[ "$pub" == "Enabled" ]]; then
    continue
  fi

  pe_n=$(echo "$detail" | jq '[.privateEndpointConnections[]?] | length')
  if [[ "${pe_n:-0}" -eq 0 ]]; then
    jq --arg t "Cosmos DB \`${acct}\` blocks public access but has no private endpoints" \
      --arg d "publicNetworkAccess=${pub}; privateEndpointConnections empty." \
      --argjson s 3 \
      --arg n "Create and approve a private endpoint for this account or re-enable controlled public access." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  bad_pe=$(echo "$detail" | jq '[.privateEndpointConnections[]? | select((.privateLinkServiceConnectionState.status // "") != "Approved")] | length')
  if [[ "${bad_pe:-0}" -gt 0 ]]; then
    pend=$(echo "$detail" | jq -c '[.privateEndpointConnections[]? | select((.privateLinkServiceConnectionState.status // "") != "Approved")]')
    jq --arg t "Cosmos DB \`${acct}\` has private endpoint connections not in Approved state" \
      --argjson d "$pend" \
      --argjson s 2 \
      --arg n "Approve or remove stale private endpoint connections in the Azure portal." \
      '. += [{title: $t, details: ($d | tostring), severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi
done

cat "$OUTPUT_FILE"
