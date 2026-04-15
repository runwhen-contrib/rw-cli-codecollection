#!/usr/bin/env bash
# Verify SPF TXT includes Mailgun (mailgun.org) for the sending domain.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_spf_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
curl -sS --max-time 60 -o /tmp/mg_dom_spf.json -u "api:${API_KEY}" "${MG_BASE}/v3/domains/${enc_domain}" >/dev/null || true

expected=$(jq -r '[.domain.sending_dns_records[]? | select((.record_type // .type // "") == "TXT") | .value // empty] | map(select(test("v=spf1"))) | first // empty' /tmp/mg_dom_spf.json 2>/dev/null || true)

txt=$(dig +short TXT "${MAILGUN_SENDING_DOMAIN}" | tr -d '"' | tr '\n' ' ')

if ! echo "$txt" | grep -qi 'v=spf1'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Missing SPF TXT for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "No v=spf1 TXT observed in public DNS. dig output: ${txt}" \
    --argjson severity 3 \
    --arg next_steps "Publish SPF TXT including Mailgun (for example include:mailgun.org) per Mailgun domain DNS instructions." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
elif ! echo "$txt" | grep -qi 'mailgun'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "SPF TXT may not authorize Mailgun for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "TXT records: ${txt}. Mailgun-recommended pattern not detected (include mailgun.org or Mailgun-provided include)." \
    --argjson severity 3 \
    --arg next_steps "Align SPF with Mailgun control panel expected value: ${expected:-see Mailgun UI}." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
