#!/usr/bin/env bash
set -euo pipefail
set -x
# HTTP 429 / throttled requests via TotalRequests with StatusCode dimension.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUTPUT_JSON="cosmosdb_throttle_issues.json"
issues_json='[]'
METRICS_LOOKBACK_DAYS="${METRICS_LOOKBACK_DAYS:-14}"
METRICS_OFFSET="${METRICS_OFFSET:-${METRICS_LOOKBACK_DAYS}d}"
THROTTLE_MIN="${THROTTLE_EVENTS_THRESHOLD:-1}"
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

  raw="$(az monitor metrics list --resource "$rid" --metric TotalRequests \
    --dimension StatusCode --filter "StatusCode eq '429'" \
    --offset "$METRICS_OFFSET" --interval PT1H --aggregation Total \
    --output json 2>/dev/null || true)"
  [[ -z "$raw" || "$raw" == "{}" ]] && continue

  total_429="$(echo "$raw" | jq '[.value[0].timeseries[]?.data[]? | (.total // 0)] | add // 0')"

  if awk -v t="$total_429" -v m="$THROTTLE_MIN" 'BEGIN{exit !(t >= m)}'; then
    issues_json="$(jq --arg t "HTTP 429 throttling observed for Cosmos DB \`$acct\`" \
      --arg d "TotalRequests with status 429 in the lookback window: ${total_429} (threshold: ${THROTTLE_MIN})." \
      --arg n "Increase provisioned RU/s or autoscale max, reduce RU-heavy queries, fix hot partitions, or enable retry policies with backoff for \`$acct\`." \
      '. += [{title:$t,details:$d,severity:4,next_steps:$n}]' <<<"$issues_json")"
  fi

done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")

echo "$issues_json" > "$OUTPUT_JSON"
echo "Wrote $OUTPUT_JSON"
