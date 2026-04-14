#!/usr/bin/env bash
# Sample recent failed events and surface patterns (API / policy / DNS hints).
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_recent_failures_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
url="${MG_BASE}/v3/domains/${enc_domain}/events?event=failed&limit=25"

http_code=$(curl -sS --max-time 90 -o /tmp/mg_ev.json -w "%{http_code}" -u "api:${API_KEY}" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_ev.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun Events API error for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code}. ${body:0:400}" \
    --argjson severity 3 \
    --arg next_steps "Verify API permissions and domain; retry later." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

count=$(jq '.items | length' /tmp/mg_ev.json)
if [[ "${count:-0}" -eq 0 ]]; then
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

summary=$(jq -r '[.items[]? | {severity: (.severity // ""), reason: (.delivery-status.message // .message // "")}] | .[0:10]' /tmp/mg_ev.json | jq -c .)

issues_json=$(echo "$issues_json" | jq \
  --arg title "Recent Mailgun permanent failures for \`${MAILGUN_SENDING_DOMAIN}\`" \
  --arg details "Sample of up to 10 failed events (raw): ${summary}" \
  --argjson severity 3 \
  --arg next_steps "Drill into Mailgun logs for these recipients; check SPF/DKIM/DMARC, recipient policy, and blocklists." \
  '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')

echo "$issues_json" >"$OUT"
cat "$OUT"
