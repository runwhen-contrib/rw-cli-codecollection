#!/usr/bin/env bash
# SLI dimension: domain state active (1/0 JSON).
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
http_code=$(curl -sS --max-time 30 -o /tmp/mg_sli_d.json -w "%{http_code}" -u "api:${API_KEY}" "${MG_BASE}/v3/domains/${enc_domain}") || true

score=0
if [[ "$http_code" == "200" ]]; then
  st=$(jq -r '.domain.state // ""' /tmp/mg_sli_d.json)
  [[ "$st" == "active" ]] && score=1
fi

jq -n --argjson s "$score" '{score: $s}'
