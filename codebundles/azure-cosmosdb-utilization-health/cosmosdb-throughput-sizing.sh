#!/usr/bin/env bash
set -euo pipefail
set -x
# Provisioned / autoscale headroom vs normalized utilization (oversizing and undersizing hints).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_throughput_sizing_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
HIGH_NRU="${NORMALIZED_RU_THRESHOLD_PCT:-80}"
LOW_NRU="${UNDERUTILIZED_NORMALIZED_PCT:-15}"
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

  nru_raw="$(az monitor metrics list --resource "$rid" --metric NormalizedRUConsumption \
    --offset "$METRICS_OFFSET" --interval PT1H --aggregation Average \
    --output json 2>/dev/null || true)"
  [[ -z "$nru_raw" || "$nru_raw" == "{}" ]] && continue

  avgs="$(echo "$nru_raw" | jq '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average]')"
  len="$(echo "$avgs" | jq 'length')"
  [[ "$len" -lt 2 ]] && continue

  max_nru="$(echo "$avgs" | jq 'max')"
  low_cnt="$(echo "$avgs" | jq --argjson l "$LOW_NRU" '[.[] | select(. < $l)] | length')"
  low_frac="$(echo "$avgs" | jq --argjson c "$low_cnt" --argjson le "$len" '($c / $le)')"

  if awk -v m="$max_nru" -v h="$HIGH_NRU" 'BEGIN{exit !(m > h)}'; then
    issues_json="$(jq --arg t "Cosmos DB \`$acct\` normalized RU near provisioned ceiling" \
      --arg d "Peak hourly average normalized RU ~${max_nru}% exceeds ${HIGH_NRU}% threshold." \
      --arg n "Increase throughput, raise autoscale maximum, or reduce per-request RU cost for \`$acct\` before customer-visible throttling." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

  prov_raw="$(az monitor metrics list --resource "$rid" --metric ProvisionedThroughput \
    --offset "$METRICS_OFFSET" --interval P1D --aggregation Average \
    --output json 2>/dev/null || true)"
  prov_avg="$(echo "$prov_raw" | jq -r '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average] | max // empty')"

  if awk -v f="$low_frac" 'BEGIN{exit !(f+0 > 0.8)}' && \
     awk -v m="$max_nru" -v l="$LOW_NRU" 'BEGIN{exit !(m+0 < l+5)}' && \
     [[ -n "$prov_avg" && "$prov_avg" != "null" ]] && \
     awk -v p="$prov_avg" 'BEGIN{exit !(p > 400)}'; then
    issues_json="$(jq --arg t "Cosmos DB \`$acct\` may be over-provisioned" \
      --arg d "Normalized RU stayed below ~${LOW_NRU}% for most samples (low fraction ${low_frac}) while ProvisionedThroughput remains elevated (recent sample ~${prov_avg} RU/s)." \
      --arg n "Consider lowering manual throughput, tightening autoscale rules, or consolidating databases to reduce cost for \`$acct\` after validating workload baselines." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
