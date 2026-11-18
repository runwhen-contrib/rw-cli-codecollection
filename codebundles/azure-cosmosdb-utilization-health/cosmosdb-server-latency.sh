#!/usr/bin/env bash
set -euo pipefail
set -x
# Server-side latency regression vs threshold (Average aggregation).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_latency_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
LAT_MS="${SERVER_LATENCY_MS_THRESHOLD:-100}"
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

  raw="$(az monitor metrics list --resource "$rid" --metric ServerSideLatency \
    --offset "$METRICS_OFFSET" --interval PT1H --aggregation Average Maximum \
    --output json 2>/dev/null || true)"
  [[ -z "$raw" || "$raw" == "{}" ]] && continue

  max_avg="$(echo "$raw" | jq -r '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average] | max // empty')"
  [[ -z "$max_avg" || "$max_avg" == "null" ]] && continue

  if awk -v m="$max_avg" -v t="$LAT_MS" 'BEGIN{exit !(m > t)}'; then
    issues_json="$(jq --arg t "Elevated server-side latency for Cosmos DB \`$acct\`" \
      --arg d "Peak hourly average ServerSideLatency ~${max_avg} ms exceeds threshold ${LAT_MS} ms in the analysis window." \
      --arg n "Correlate with normalized RU, throttling, and query patterns. Tune indexing, partition spread, and SDK consistency level for \`$acct\`." \
      '. += [{title:$t,details:$d,severity:3,next_steps:$n}]' <<<"$issues_json")"
  fi

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
