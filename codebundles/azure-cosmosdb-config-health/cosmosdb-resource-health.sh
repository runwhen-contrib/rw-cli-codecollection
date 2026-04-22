#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Resource Health (Microsoft.ResourceHealth) for Cosmos DB accounts.
# Writes JSON array of issues to cosmosdb_resource_health_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_resource_health_issues.json"
echo '[]' > "$OUTPUT_FILE"

subscription="$(cosmosdb_resolve_subscription)"
if [[ -z "$subscription" ]]; then
  jq -n --arg t "Cannot resolve Azure subscription" \
    --arg d "Set AZ_SUBSCRIPTION or log in with Azure CLI." \
    --arg n "Verify AZ_SUBSCRIPTION and azure_credentials." \
    '[{title: $t, details: $d, severity: 4, next_steps: $n}]' > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

az account set --subscription "$subscription" 2>/dev/null || {
  jq -n --arg t "Failed to set Azure subscription" \
    --arg d "az account set failed for subscription ${subscription}" \
    --arg n "Verify credentials and subscription access." \
    '[{title: $t, details: $d, severity: 4, next_steps: $n}]' > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
}

reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
if [[ "$reg_state" != "Registered" ]]; then
  az provider register --namespace Microsoft.ResourceHealth 2>/dev/null || true
  for _ in {1..12}; do
    reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null || echo "")
    [[ "$reg_state" == "Registered" ]] && break
    sleep 10
  done
fi

if [[ "$reg_state" != "Registered" ]]; then
  jq -n --arg t "Microsoft.ResourceHealth provider not registered" \
    --arg d "Registration state: ${reg_state}" \
    --arg n "Register Microsoft.ResourceHealth for the subscription or retry later." \
    '[{title: $t, details: $d, severity: 3, next_steps: $n}]' > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
mapfile -t accounts < <(cosmosdb_account_names "$subscription" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

if [[ ${#accounts[@]} -eq 0 || -z "${accounts[0]:-}" ]]; then
  jq -n --arg t "No Cosmos DB accounts found in resource group" \
    --arg d "Resource group: ${AZURE_RESOURCE_GROUP}; filter: ${COSMOS_FILTER}" \
    --arg n "Confirm account names, resource group, and subscription." \
    '[{title: $t, details: $d, severity: 3, next_steps: $n}]' > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

for acct in "${accounts[@]}"; do
  [[ -z "$acct" ]] && continue
  url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.DocumentDB/databaseAccounts/${acct}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"
  if ! health=$(az rest --method get --url "$url" -o json 2>/dev/null); then
    jq --arg t "Resource Health query failed for \`${acct}\`" \
      --arg d "Could not retrieve availability status from Resource Health API." \
      --arg n "Verify Reader access and that the account exists." \
      --argjson s 3 \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi
  title=$(echo "$health" | jq -r '.properties.title // "Unknown"')
  if [[ "$title" != "Available" ]]; then
    details=$(echo "$health" | jq -c '{title: .properties.title, reason: .properties.reasonType, summary: .properties.summary, occurred: .properties.occuredTime}')
    jq --arg t "Cosmos DB \`${acct}\` reports Resource Health: ${title}" \
      --argjson d "$details" \
      --argjson s 2 \
      --arg n "Review Azure Service Health and Cosmos DB status; engage Azure support if outage persists." \
      '. += [{title: $t, details: ($d | tostring), severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi
done

echo "Wrote ${OUTPUT_FILE}"
cat "$OUTPUT_FILE"
