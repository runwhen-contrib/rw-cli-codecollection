#!/usr/bin/env bash
set -euo pipefail
set -x
# Normalized RU time-series: sustained high utilization and upward trend vs first half of window.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_normalized_ru_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
THRESH="${NORMALIZED_RU_THRESHOLD_PCT:-80}"
COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"

sub="$(cosmosdb_resolve_subscription)"
if [[ -z "$sub" ]]; then
  echo "[]" > "$OUTPUT_JSON"
  echo "No subscription context; wrote empty issues."
  exit 0
fi

az account set --subscription "$sub"

while IFS= read -r acct; do
  [[ -z "$acct" ]] && continue
  rid="$(cosmosdb_resource_id "$sub" "$AZURE_RESOURCE_GROUP" "$acct")"
  [[ -z "$rid" ]] && continue

  raw="$(az monitor metrics list --resource "$rid" --metric NormalizedRUConsumption \
    --offset "$METRICS_OFFSET" --interval PT1H --aggregation Average Maximum \
    --output json 2>/dev/null || true)"
  [[ -z "$raw" || "$raw" == "{}" ]] && continue

  avgs="$(echo "$raw" | jq '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average]')"
  len="$(echo "$avgs" | jq 'length')"
  if [[ "$len" -lt 2 ]]; then
    continue
  fi

  high_cnt="$(echo "$avgs" | jq --argjson t "$THRESH" '[.[] | select(. > $t)] | length')"
  high_frac="$(echo "$avgs" | jq --argjson hc "$high_cnt" --argjson l "$len" '($hc / $l)')"

  half=$((len / 2))
  first_avg="$(echo "$avgs" | jq --argjson h "$half" '.[0:$h] | add / length')"
  second_avg="$(echo "$avgs" | jq --argjson h "$half" '.[$h:] | add / length')"
  trend_up="$(echo "$second_avg $first_avg" | awk '{if ($2 > 0 && ($1 / $2) > 1.15) print 1; else print 0}')"

  if awk -v f="$high_frac" 'BEGIN{exit !(f+0 > 0.5)}'; then
    issues_json="$(jq --arg t "Sustained high Normalized RU for Cosmos DB \`$acct\`" \
      --arg d "More than half of hourly samples exceed ${THRESH}% normalized RU (fraction high: ${high_frac})." \
      --arg n "Review hot partitions, partition keys, and provisioned throughput or autoscale max for account \`$acct\`. Consider Azure Advisor and Metrics explorer with DatabaseName/CollectionName dimensions." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

  if [[ "$trend_up" == "1" ]] && awk -v s="$second_avg" -v t="$THRESH" 'BEGIN{exit !(s+0 > (t * 0.6))}'; then
    issues_json="$(jq --arg t "Rising Normalized RU pressure for Cosmos DB \`$acct\`" \
      --arg d "Second-half average normalized RU (~${second_avg}%) is materially higher than first-half (~${first_avg}%) while remaining elevated." \
      --arg n "Investigate workload growth, indexing changes, and cross-partition queries for \`$acct\`. Plan throughput increases before throttling spreads." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
