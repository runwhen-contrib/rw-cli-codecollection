#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Diagnostic settings (metrics / logs) destinations.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_diagnostic_issues.json"
echo '[]' > "$OUTPUT_FILE"

subscription="$(cosmosdb_resolve_subscription)"
[[ -z "$subscription" ]] && exit 0
az account set --subscription "$subscription" 2>/dev/null || exit 0

COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
mapfile -t accounts < <(cosmosdb_account_names "$subscription" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")
[[ ${#accounts[@]} -eq 0 || -z "${accounts[0]:-}" ]] && { echo '[]' > "$OUTPUT_FILE"; cat "$OUTPUT_FILE"; exit 0; }

for acct in "${accounts[@]}"; do
  [[ -z "$acct" ]] && continue
  rid="$(cosmosdb_account_resource_id "$subscription" "$AZURE_RESOURCE_GROUP" "$acct")"
  if ! settings=$(az monitor diagnostic-settings list --resource "$rid" --subscription "$subscription" -o json 2>/dev/null); then
    jq --arg t "Cannot list diagnostic settings for \`${acct}\`" \
      --arg d "az monitor diagnostic-settings list failed for ${rid}" \
      --argjson s 3 \
      --arg n "Verify Monitoring Reader or equivalent on the subscription/resource." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  n=$(echo "$settings" | jq 'if type == "array" then length else [.value[]?] | length end')
  if [[ "${n:-0}" -eq 0 ]]; then
    jq --arg t "Cosmos DB \`${acct}\` has no diagnostic settings" \
      --arg d "No diagnostic settings send metrics or logs to Log Analytics, storage, or Event Hub." \
      --argjson s 3 \
      --arg n "Configure diagnostic settings to stream control-plane metrics/logs for audit and troubleshooting." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
  fi
done

cat "$OUTPUT_FILE"
