#!/usr/bin/env bash
# Compare delivered vs failed totals from Mailgun stats/total to a minimum success percentage.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_STATS_WINDOW_HOURS:-24}"
: "${MAILGUN_MIN_DELIVERY_SUCCESS_PCT:-95}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_delivery_success_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
dur_h="${MAILGUN_STATS_WINDOW_HOURS}"
url="${MG_BASE}/v3/domains/${enc_domain}/stats/total?event=delivered,failed&duration=${dur_h}h"

http_code=$(curl -sS --max-time 90 -o /tmp/mg_stats.json -w "%{http_code}" -u "api:${API_KEY}" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_stats.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun stats API error for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code} fetching delivery stats. ${body:0:400}" \
    --argjson severity 3 \
    --arg next_steps "Confirm the domain name, API region, and key permissions; retry after backoff if rate-limited." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

# Sum delivered and failed across time buckets
read -r delivered failed < <(jq -r '
  def sumdel: [.stats[]? | .delivered // empty | .. | numbers] | add // 0;
  def sumfail: [.stats[]? | .failed // empty | .. | numbers] | add // 0;
  [sumdel, sumfail] | @tsv
' /tmp/mg_stats.json)

total=$((delivered + failed))
if [[ "$total" -eq 0 ]]; then
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

pct=$(awk -v d="$delivered" -v t="$total" 'BEGIN { printf "%.4f", (100.0 * d / t) }')
min="${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}"

if awk -v p="$pct" -v m="$min" 'BEGIN { exit !(p + 0 < m + 0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Low Mailgun delivery success rate for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Window: ${dur_h}h. Delivered: ${delivered}, failed (all failure buckets summed): ${failed}. Success rate ${pct}% (minimum ${min}%)." \
    --argjson severity 3 \
    --arg next_steps "Inspect recent failures and recipient list quality; check Mailgun logs and DNS/auth for this domain." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
