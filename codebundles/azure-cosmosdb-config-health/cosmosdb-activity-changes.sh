#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Recent Administrative activity log events for the account (config mutations).
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_common.sh
source "${SCRIPT_DIR}/cosmosdb_common.sh"

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"

OUTPUT_FILE="cosmosdb_activity_issues.json"
echo '[]' > "$OUTPUT_FILE"

LOOKBACK_HOURS="${ACTIVITY_LOG_LOOKBACK_HOURS:-168}"
# az monitor activity-log --offset expects formats like 168h
OFFSET="${LOOKBACK_HOURS}h"

subscription="$(cosmosdb_resolve_subscription)"
[[ -z "$subscription" ]] && exit 0
az account set --subscription "$subscription" 2>/dev/null || exit 0

COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
mapfile -t accounts < <(cosmosdb_account_names "$subscription" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")
[[ ${#accounts[@]} -eq 0 || -z "${accounts[0]:-}" ]] && { echo '[]' > "$OUTPUT_FILE"; cat "$OUTPUT_FILE"; exit 0; }

for acct in "${accounts[@]}"; do
  [[ -z "$acct" ]] && continue
  rid="$(cosmosdb_account_resource_id "$subscription" "$AZURE_RESOURCE_GROUP" "$acct")"
  if ! log_json=$(az monitor activity-log list --resource-id "$rid" --offset "$OFFSET" --max-events 100 --subscription "$subscription" -o json 2>/dev/null); then
    jq --arg t "Cannot read activity log for \`${acct}\`" \
      --arg d "az monitor activity-log list failed." \
      --argjson s 3 \
      --arg n "Verify Reader access on the subscription and resource." \
      '. += [{title: $t, details: $d, severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
    continue
  fi

  admin_events=$(echo "$log_json" | jq '[.[] | select(
    .category.value == "Administrative" or .category.localizedValue == "Administrative" or .category == "Administrative"
  )]')
  count=$(echo "$admin_events" | jq 'length')
  if [[ "${count:-0}" -eq 0 ]]; then
    continue
  fi

  sample=$(echo "$admin_events" | jq -c '[.[:15][] | {time: .eventTimestamp, op: .operationName.localizedValue, status: .status.localizedValue}]')
  jq --arg t "Cosmos DB \`${acct}\` has ${count} administrative activity log events in last ${LOOKBACK_HOURS}h" \
    --argjson d "$sample" \
    --argjson s 3 \
    --arg n "Review who changed throughput, failover, networking, or backup; correlate with incidents or change windows." \
    '. += [{title: $t, details: ($d | tostring), severity: $s, next_steps: $n}]' "$OUTPUT_FILE" > tmp.$$.json && mv tmp.$$.json "$OUTPUT_FILE"
done

cat "$OUTPUT_FILE"
