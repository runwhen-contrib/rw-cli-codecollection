#!/usr/bin/env bash
# SLI dimension: delivery success vs MAILGUN_MIN_DELIVERY_SUCCESS_PCT (1/0 JSON).
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_STATS_WINDOW_HOURS:-24}"
: "${MAILGUN_MIN_DELIVERY_SUCCESS_PCT:-95}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

dur_h="${MAILGUN_STATS_WINDOW_HOURS}"
url="${MG_BASE}/v1/analytics/metrics"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  --arg dur "${dur_h}h" \
  '{
    duration: $dur,
    metrics: ["delivered_count", "failed_count"],
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    include_aggregates: true
  }')

http_code=$(curl -sS --max-time 45 \
  -o /tmp/mg_sli_st.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

score=1
if [[ "$http_code" != "200" ]]; then
  jq -n '{score: 0}'
  exit 0
fi

delivered=$(jq -r '.aggregates.metrics.delivered_count // 0' /tmp/mg_sli_st.json)
failed=$(jq -r '.aggregates.metrics.failed_count // 0' /tmp/mg_sli_st.json)

total=$((delivered + failed))
if [[ "$total" -eq 0 ]]; then
  jq -n '{score: 1}'
  exit 0
fi

pct=$(awk -v d="$delivered" -v t="$total" 'BEGIN { printf "%.6f", (100.0 * d / t) }')
min="${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}"
if awk -v p="$pct" -v m="$min" 'BEGIN { exit !(p + 0 < m + 0) }'; then
  score=0
else
  score=1
fi

jq -n --argjson s "$score" '{score: $s}'
