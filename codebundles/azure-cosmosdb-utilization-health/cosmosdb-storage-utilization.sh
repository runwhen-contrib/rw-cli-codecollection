#!/usr/bin/env bash
set -euo pipefail
set -x
# DataUsage + IndexUsage growth across the lookback window.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_storage_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
GROWTH_PCT="${STORAGE_GROWTH_PCT_THRESHOLD:-25}"
COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"

sub="$(cosmosdb_resolve_subscription)"
if [[ -z "$sub" ]]; then
  echo "[]" > "$OUTPUT_JSON"
  exit 0
fi

az account set --subscription "$sub"

storage_growth_issue() {
  local acct="$1" metric="$2" json="$3"
  local series first last pct
  series="$(echo "$json" | jq '[.value[0].timeseries[0].data[]? | (.average // .maximum // 0)] | map(select(. > 0))')"
  local n
  n="$(echo "$series" | jq 'length')"
  [[ "$n" -lt 2 ]] && return 0
  first="$(echo "$series" | jq '.[0]')"
  last="$(echo "$series" | jq '.[-1]')"
  [[ "$first" == "0" ]] && return 0
  pct="$(echo "$series" | awk -v f="$first" -v l="$last" 'BEGIN{printf "%.2f", (l-f)/f*100}')"
  if awk -v p="$pct" -v g="$GROWTH_PCT" 'BEGIN{exit !(p > g)}'; then
    issues_json="$(jq --arg t "Rapid ${metric} growth for Cosmos DB \`$acct\`" \
      --arg d "${metric} grew ~${pct}% from the start to the end of the ${METRICS_LOOKBACK_DAYS}d window (threshold ${GROWTH_PCT}%)." \
      --arg n "Plan partition count, indexing cost, and storage billing impacts for \`$acct\`. Review TTL, archival, and analytical store if applicable." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi
}

while IFS= read -r acct; do
  [[ -z "$acct" ]] && continue
  rid="$(cosmosdb_resource_id "$sub" "$AZURE_RESOURCE_GROUP" "$acct")"
  [[ -z "$rid" ]] && continue

  for metric in DataUsage IndexUsage; do
    raw="$(az monitor metrics list --resource "$rid" --metric "$metric" \
      --offset "$METRICS_OFFSET" --interval P1D --aggregation Average Maximum \
      --output json 2>/dev/null || true)"
    [[ -z "$raw" || "$raw" == "{}" ]] && continue
    storage_growth_issue "$acct" "$metric" "$raw"
  done

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
