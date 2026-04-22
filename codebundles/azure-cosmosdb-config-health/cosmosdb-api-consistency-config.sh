#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# API / consistency / capability flags vs common production baselines.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_api_consistency_issues.json"
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
    jq --arg t "Cannot read Cosmos DB account \`${acct}\`" \
      --arg d "az cosmosdb show failed." \
      --argjson s 3 \
      --arg n "Verify RBAC Reader on the account." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  defcons=$(echo "$detail" | jq -r '.consistencyPolicy.defaultConsistencyLevel // ""')
  if [[ "$defcons" == "Eventual" ]]; then
    jq --arg t "Cosmos DB \`${acct}\` uses Eventual default consistency" \
      --arg d "defaultConsistencyLevel=${defcons}. Many production workloads expect Session or stronger guarantees." \
      --argjson s 2 \
      --arg n "Re-evaluate consistency tier for application correctness; consider Session or Bounded Staleness if reads require freshness." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi

  mwl=$(echo "$detail" | jq -r '.enableMultipleWriteLocations // false')
  loc_count=$(echo "$detail" | jq '[.locations[]?] | length')
  if [[ "$mwl" == "true" ]] && [[ "${loc_count:-0}" -lt 2 ]]; then
    jq --arg t "Cosmos DB \`${acct}\` has multi-region writes enabled with a single region" \
      --arg d "enableMultipleWriteLocations=true but locations count=${loc_count}." \
      --argjson s 2 \
      --arg n "Add a second write region or disable multi-region writes if not required." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi

  dk=$(echo "$detail" | jq -r '.disableKeyBasedMetadataWriteAccess // false')
  if [[ "$dk" != "true" ]]; then
    jq --arg t "Cosmos DB \`${acct}\` allows key-based metadata writes" \
      --arg d "disableKeyBasedMetadataWriteAccess is not true; account metadata can be changed with keys." \
      --argjson s 2 \
      --arg n "Consider setting disableKeyBasedMetadataWriteAccess and using Azure RBAC for control-plane changes." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi
done

cat "$OUTPUT_FILE"
