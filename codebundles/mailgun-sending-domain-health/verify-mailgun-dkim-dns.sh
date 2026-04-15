#!/usr/bin/env bash
# Compare published DKIM TXT against Mailgun domain API expected records.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_dkim_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

enc_domain=$(printf '%s' "${MAILGUN_SENDING_DOMAIN}" | jq -sRr @uri)
http_code=$(curl -sS --max-time 60 -o /tmp/mg_dkim.json -w "%{http_code}" -u "api:${API_KEY}" "${MG_BASE}/v3/domains/${enc_domain}") || true

if [[ "$http_code" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot load Mailgun domain for DKIM check on \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code}" \
    --argjson severity 3 \
    --arg next_steps "Fix API access then re-run." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | jq -r '.name')
  want=$(echo "$line" | jq -r '.value' | tr -d '\n')
  active=$(echo "$line" | jq -r '.active')
  short=$(echo "$name" | sed 's/\.$//')
  got=$(dig +short TXT "$short" | tr -d '"' | tr '\n' ' ')
  if [[ "$active" != "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DKIM not verified in Mailgun for \`${MAILGUN_SENDING_DOMAIN}\`" \
      --arg details "Record ${name} inactive in Mailgun." \
      --argjson severity 3 \
      --arg next_steps "Publish DKIM TXT at ${name} exactly as shown in Mailgun." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  elif [[ -n "$want" ]] && ! echo "$got" | grep -qF "$want"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "DKIM TXT mismatch for \`${MAILGUN_SENDING_DOMAIN}\`" \
      --arg details "Selector ${name}: expected contains Mailgun value; dig returned: ${got}" \
      --argjson severity 3 \
      --arg next_steps "Update DNS TXT at ${name} to match Mailgun; allow propagation." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
done < <(jq -c '.domain.sending_dns_records[]? | select((.record_type // .type // "") == "TXT" and ((.name // "") | test("_domainkey")))' /tmp/mg_dkim.json 2>/dev/null || true)

echo "$issues_json" >"$OUT"
cat "$OUT"
