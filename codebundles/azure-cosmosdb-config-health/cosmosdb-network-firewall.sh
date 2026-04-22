#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Public network access and IP firewall rules.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_network_issues.json"
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
    jq --arg t "Cannot read network settings for \`${acct}\`" \
      --arg d "az cosmosdb show failed." \
      --argjson s 3 \
      --arg n "Verify Reader access." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  pub=$(echo "$detail" | jq -r '.publicNetworkAccess // "Enabled"')
  ip_count=$(echo "$detail" | jq '[.ipRules[]?] | length')
  open_ip=$(echo "$detail" | jq '[.ipRules[]? | select(.ipAddressOrRange == "0.0.0.0")] | length')

  if [[ "${open_ip:-0}" -gt 0 ]]; then
    jq --arg t "Cosmos DB \`${acct}\` allows 0.0.0.0 in IP firewall" \
      --arg d "ipRules include 0.0.0.0 which is overly permissive." \
      --argjson s 3 \
      --arg n "Remove open internet rules; restrict to known egress IPs or private endpoints." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi

  if [[ "$pub" == "Enabled" ]] && [[ "${ip_count:-0}" -eq 0 ]]; then
    pe_count=$(echo "$detail" | jq '[.privateEndpointConnections[]?] | length')
    if [[ "${pe_count:-0}" -eq 0 ]]; then
      jq --arg t "Cosmos DB \`${acct}\` is reachable from public network without IP rules" \
        --arg d "publicNetworkAccess=Enabled and no ipRules; no private endpoints." \
        --argjson s 2 \
        --arg n "Disable public access and use private endpoints, or restrict with IP firewall / VNet integration." \
        '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    fi
  fi
done

cat "$OUTPUT_FILE"
