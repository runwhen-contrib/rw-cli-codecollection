#!/usr/bin/env bash
# Fetch Mailgun domain details; emit issues JSON for verification state.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?Must set MAILGUN_SENDING_DOMAIN}"
: "${MAILGUN_API_REGION:?Must set MAILGUN_API_REGION}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_domain_state_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
url="${MG_BASE}/v3/domains/${enc_domain}"

http_code=$(curl -sS --max-time 60 -o /tmp/mg_domain.json -w "%{http_code}" -u "api:${API_KEY}" "$url") || true

if [[ "$http_code" != "200" ]]; then
  err_body=$(cat /tmp/mg_domain.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun domain API error for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code} from Mailgun Domains API. Body (truncated): ${err_body:0:500}" \
    --argjson severity 4 \
    --arg next_steps "Verify MAILGUN_API_REGION matches the domain, the API key has access, and the domain exists in this Mailgun account." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  echo "Wrote $OUT"
  exit 0
fi

state=$(jq -r '.domain.state // "unknown"' /tmp/mg_domain.json)
if [[ "$state" != "active" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun domain not active: \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Domain state is ${state} (expected active)." \
    --argjson severity 3 \
    --arg next_steps "Complete domain verification in Mailgun or remove stale domain configuration." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

# sending_dns_records: flag inactive required records
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun DNS record not verified for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "$line" \
    --argjson severity 3 \
    --arg next_steps "Publish or fix the DNS records shown in Mailgun for this domain; wait for DNS propagation and re-verify." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
done < <(jq -r '.domain.sending_dns_records[]? | select(.active == false) | "\(.record_type // .type // "?") \(.name // ""): \(.value // "")"' /tmp/mg_domain.json 2>/dev/null || true)

echo "$issues_json" >"$OUT"
echo "Wrote $OUT"
cat "$OUT"
