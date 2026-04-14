#!/usr/bin/env bash
# Check _dmarc TXT presence and basic policy keywords for the sending domain.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"

OUT="mailgun_dmarc_issues.json"
issues_json='[]'

org_domain="${MAILGUN_SENDING_DOMAIN}"
dmarc_name="_dmarc.${org_domain}"

txt=$(dig +short TXT "$dmarc_name" | tr -d '"' | tr '\n' ' ')

if ! echo "$txt" | grep -qi 'v=DMARC1'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "DMARC record missing or invalid for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Query ${dmarc_name} TXT: ${txt:-<empty>}" \
    --argjson severity 2 \
    --arg next_steps "Publish a DMARC TXT at _dmarc.${org_domain} (v=DMARC1; p=none|quarantine|reject) aligned with your org policy." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
