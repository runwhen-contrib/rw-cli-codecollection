#!/usr/bin/env bash
# Sample recent rejected events — messages Mailgun refused to process
# (suppression matches, policy blocks, invalid recipients).
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_rejected_events_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

url="${MG_BASE}/v1/analytics/logs"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  '{
    duration: "5d",
    events: ["rejected"],
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    pagination: { sort: "timestamp:desc", limit: 50 }
  }')

http_code=$(curl -sS --max-time 90 \
  -o /tmp/mg_rejected.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_rejected.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun Logs API error fetching rejected events for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code}. ${body:0:400}" \
    --argjson severity 3 \
    --arg next_steps "Verify API key permissions (Analyst+ required) and domain; retry later." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

count=$(jq '.items | length' /tmp/mg_rejected.json)

if [[ "${count:-0}" -eq 0 ]]; then
  echo "No rejected events found for ${MAILGUN_SENDING_DOMAIN} in the last 5 days."
  echo "This means Mailgun is NOT blocking or refusing any messages for this domain."
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

echo "=== ${count} Rejected Event(s) for ${MAILGUN_SENDING_DOMAIN} (last 5 days) ==="
echo ""
echo "Mailgun rejected these messages before attempting delivery (suppressions, policy, invalid recipients):"
echo ""

jq -r '.items[] |
  "  \(."@timestamp" // "?")  \(.reject.reason // .reason // "unknown reason")  to=\(.message.headers.to // .recipient // "?")  from=\(.message.headers.from // "?")"
' /tmp/mg_rejected.json

echo ""

# Summarize rejection reasons
echo "--- Rejection Reason Summary ---"
jq -r '[.items[] | .reject.reason // .reason // "unknown"] | group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count)[] | "  \(.count)x \(.reason)"' /tmp/mg_rejected.json
echo ""

if [[ "$count" -gt 5 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun rejecting messages for \`${MAILGUN_SENDING_DOMAIN}\`: ${count} in last 5 days" \
    --arg details "$(jq -r '[.items[] | .reject.reason // .reason // "unknown"] | group_by(.) | map("\(length)x \(.[0])") | join(", ")' /tmp/mg_rejected.json)" \
    --argjson severity 2 \
    --arg next_steps "Review rejection reasons. Suppressions: clean bounce/complaint lists. Policy: check Mailgun account settings. Invalid: fix recipient validation in the sending application." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
