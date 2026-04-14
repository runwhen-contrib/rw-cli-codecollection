#!/usr/bin/env bash
# Optional: validate MX when MAILGUN_VERIFY_MX=true using Mailgun receiving_dns_records as ground truth.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_VERIFY_MX:-false}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_mx_issues.json"
issues_json='[]'

low=$(echo "${MAILGUN_VERIFY_MX}" | tr '[:upper:]' '[:lower:]')
if [[ "$low" != "true" && "$low" != "1" && "$low" != "yes" ]]; then
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
curl -sS --max-time 60 -o /tmp/mg_mx.json -u "api:${API_KEY}" "${MG_BASE}/v3/domains/${enc_domain}" >/dev/null || true

want_mx=$(jq -r '[.domain.receiving_dns_records[]? | select((.record_type // .type // "") == "MX") | .value // empty] | join(",")' /tmp/mg_mx.json 2>/dev/null || true)

mx_pub=$(dig +short MX "${MAILGUN_SENDING_DOMAIN}" | sort | tr '\n' ' ')

if [[ -z "$mx_pub" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No MX records published for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "MAILGUN_VERIFY_MX=true but dig returned empty. Mailgun expected MX targets (from API): ${want_mx:-unknown}" \
    --argjson severity 3 \
    --arg next_steps "If this domain receives mail via Mailgun routes, publish MX per Mailgun inbound docs; otherwise set MAILGUN_VERIFY_MX=false for send-only domains." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
elif [[ -n "$want_mx" ]] && ! echo "$mx_pub" | grep -qi "mailgun"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "MX may not match Mailgun receiving configuration for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Published MX: ${mx_pub}. Mailgun API receiving hints: ${want_mx}" \
    --argjson severity 3 \
    --arg next_steps "Confirm inbound routing design; align MX with Mailgun or hybrid provider documentation." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
