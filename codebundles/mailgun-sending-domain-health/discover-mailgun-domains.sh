#!/usr/bin/env bash
# List Mailgun sending domains (first page) as JSON array for runbook discovery.
set -euo pipefail
set -x

: "${MAILGUN_API_REGION:?Must set MAILGUN_API_REGION (us or eu)}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

resp="$(curl -sS --max-time 60 -u "api:${API_KEY}" "${MG_BASE}/v3/domains?limit=100")" || {
  echo "[]"
  exit 0
}

echo "$resp" | jq -c '[.items[]?.name // empty] | map(select(length > 0))'
