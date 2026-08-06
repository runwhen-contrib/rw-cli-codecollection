#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Backup policy: periodic retention vs continuous backup presence.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_backup_issues.json"
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
    jq --arg t "Cannot read backup policy for \`${acct}\`" \
      --arg d "az cosmosdb show failed." \
      --argjson s 3 \
      --arg n "Verify Reader access." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  btype=$(echo "$detail" | jq -r '.backupPolicy.type // "unknown"')

  if [[ "$btype" == "Continuous" ]]; then
    # Continuous backup — good for PITR; optional check for migration window
    continue
  fi

  if [[ "$btype" == "Periodic" ]]; then
    ret_h=$(echo "$detail" | jq -r '.backupPolicy.periodicModeProperties.backupRetentionIntervalInHours // 0 | tonumber')
    if [[ "${ret_h:-0}" -lt 8 ]]; then
      jq --arg t "Cosmos DB \`${acct}\` has short periodic backup retention" \
        --arg d "backupRetentionIntervalInHours=${ret_h} (below common 8h minimum for operational recovery)." \
        --argjson s 2 \
        --arg n "Increase backup retention or migrate to continuous backup for point-in-time restore." \
        '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    fi
    continue
  fi

  jq --arg t "Cosmos DB \`${acct}\` backup policy is unclear or missing" \
    --arg d "backupPolicy.type=${btype}" \
    --argjson s 3 \
    --arg n "Confirm backup is enabled in the Azure portal and API version supports backupPolicy." \
    '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
done

cat "$OUTPUT_FILE"
