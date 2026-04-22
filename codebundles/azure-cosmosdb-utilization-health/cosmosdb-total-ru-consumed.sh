#!/usr/bin/env bash
set -euo pipefail
set -x
# Total Request Units consumed: detect sharp growth in daily totals (chargeback / workload spike signal).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_total_ru_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
GROWTH_RATIO="${RU_DAILY_GROWTH_RATIO:-1.5}"
COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"

sub="$(cosmosdb_resolve_subscription)"
if [[ -z "$sub" ]]; then
  echo "[]" > "$OUTPUT_JSON"
  exit 0
fi

az account set --subscription "$sub"

while IFS= read -r acct; do
  [[ -z "$acct" ]] && continue
  rid="$(cosmosdb_resource_id "$sub" "$AZURE_RESOURCE_GROUP" "$acct")"
  [[ -z "$rid" ]] && continue

  raw="$(az monitor metrics list --resource "$rid" --metric TotalRequestUnits \
    --offset "$METRICS_OFFSET" --interval P1D --aggregation Total \
    --output json 2>/dev/null || true)"
  [[ -z "$raw" || "$raw" == "{}" ]] && continue

  daily="$(echo "$raw" | jq '[.value[0].timeseries[0].data[]? | (.total // 0)]')"
  n="$(echo "$daily" | jq 'length')"
  if [[ "$n" -lt 4 ]]; then
    continue
  fi

  mid=$((n / 2))
  first_half_avg="$(echo "$daily" | jq --argjson m "$mid" '.[0:$m] | add / length')"
  second_half_avg="$(echo "$daily" | jq --argjson m "$mid" '.[$m:] | add / length')"

  if awk -v a="$second_half_avg" -v b="$first_half_avg" -v r="$GROWTH_RATIO" 'BEGIN{exit !(b > 0 && a > b * r)}'; then
    issues_json="$(jq --arg t "Sharp increase in Total RU consumed for Cosmos DB \`$acct\`" \
      --arg d "Daily TotalRequestUnits average in the later window (~${second_half_avg}) exceeds ${GROWTH_RATIO}x the earlier window (~${first_half_avg}) over ${METRICS_LOOKBACK_DAYS}d." \
      --arg n "Validate whether traffic, batch jobs, or indexing drove RU growth for \`$acct\`. Update capacity, autoscale max, or partition strategy before sustained throttling." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
