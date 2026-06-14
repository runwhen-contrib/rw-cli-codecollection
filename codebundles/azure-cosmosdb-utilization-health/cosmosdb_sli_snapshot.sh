#!/usr/bin/env bash
set -euo pipefail
set -x
# Lightweight metric snapshot for SLI (short window).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cosmosdb_metrics_lib.sh
source "${SCRIPT_DIR}/cosmosdb_metrics_lib.sh"

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

OUT="cosmosdb_sli_output.json"
SLI_OFFSET="${SLI_METRICS_OFFSET:-2d}"
COSMOS_FILTER="${COSMOSDB_ACCOUNT_NAME:-All}"
THRESH="${NORMALIZED_RU_THRESHOLD_PCT:-80}"
THROTTLE_MIN="${THROTTLE_EVENTS_THRESHOLD:-1}"
LAT_MS="${SERVER_LATENCY_MS_THRESHOLD:-100}"

sub="$(cosmosdb_resolve_subscription)"
normalized_ok=1
throttle_ok=1
latency_ok=1

if [[ -n "$sub" ]]; then
  az account set --subscription "$sub"
  while IFS= read -r acct; do
    [[ -z "$acct" ]] && continue
    rid="$(cosmosdb_resource_id "$sub" "$AZURE_RESOURCE_GROUP" "$acct")"
    [[ -z "$rid" ]] && continue

    nru_raw="$(az monitor metrics list --resource "$rid" --metric NormalizedRUConsumption \
      --offset "$SLI_OFFSET" --interval PT1H --aggregation Average \
      --output json 2>/dev/null || true)"
    max_nru="$(echo "$nru_raw" | jq -r '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average] | max // empty')"
    if [[ -n "$max_nru" && "$max_nru" != "null" ]]; then
      if awk -v m="$max_nru" -v t="$THRESH" 'BEGIN{exit !(m > t)}'; then
        normalized_ok=0
      fi
    fi

    raw429="$(az monitor metrics list --resource "$rid" --metric TotalRequests \
      --dimension StatusCode --filter "StatusCode eq '429'" \
      --offset "$SLI_OFFSET" --interval PT1H --aggregation Total \
      --output json 2>/dev/null || true)"
    tot="$(echo "$raw429" | jq '[.value[0].timeseries[]?.data[]? | (.total // 0)] | add // 0')"
    if awk -v t="$tot" -v m="$THROTTLE_MIN" 'BEGIN{exit !(t >= m)}'; then
      throttle_ok=0
    fi

    lat_raw="$(az monitor metrics list --resource "$rid" --metric ServerSideLatency \
      --offset "$SLI_OFFSET" --interval PT1H --aggregation Average \
      --output json 2>/dev/null || true)"
    max_lat="$(echo "$lat_raw" | jq -r '[.value[0].timeseries[]?.data[]? | select(.average != null) | .average] | max // empty')"
    if [[ -n "$max_lat" && "$max_lat" != "null" ]]; then
      if awk -v m="$max_lat" -v t="$LAT_MS" 'BEGIN{exit !(m > t)}'; then
        latency_ok=0
      fi
    fi
  done < <(cosmosdb_account_names "$sub" "$AZURE_RESOURCE_GROUP" "$COSMOS_FILTER")
fi

jq -n \
  --argjson n "$normalized_ok" \
  --argjson th "$throttle_ok" \
  --argjson l "$latency_ok" \
  '{normalized_ru_ok:$n, throttle_ok:$th, latency_ok:$l}' > "$OUT"
echo "Wrote $OUT"
