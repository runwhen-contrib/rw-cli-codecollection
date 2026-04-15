#!/usr/bin/env bash
# Sample recent delivered messages via the Analytics Logs API.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_DELIVERED_SAMPLE_SIZE:-10}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_delivered_sample.json"

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

url="${MG_BASE}/v1/analytics/logs"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  --argjson limit "${MAILGUN_DELIVERED_SAMPLE_SIZE}" \
  '{
    duration: "5d",
    events: ["delivered"],
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    pagination: { sort: "timestamp:desc", limit: $limit }
  }')

http_code=$(curl -sS --max-time 90 \
  -o /tmp/mg_delivered.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_delivered.json 2>/dev/null || true)
  echo "ERROR: HTTP ${http_code} from Mailgun Logs API. ${body:0:400}"
  jq -n '[]' >"$OUT"
  cat "$OUT"
  exit 0
fi

count=$(jq '.items | length' /tmp/mg_delivered.json)

if [[ "${count:-0}" -eq 0 ]]; then
  echo "No delivered messages found for ${MAILGUN_SENDING_DOMAIN} in the last 7 days."
  jq -n '[]' >"$OUT"
  cat "$OUT"
  exit 0
fi

echo "=== Recent Delivered Messages for ${MAILGUN_SENDING_DOMAIN} (${count} sampled) ==="
echo ""

jq -r '.items[] |
  "  \(."@timestamp" // "?")  \(.message.headers.from // "?") -> \(.message.headers.to // .recipient // "?")  subj=\"\(.message.headers.subject // "?")\"  via=\(.delivery_status.mx_host // ."delivery-status"."mx-host" // "?")  tls=\(.delivery_status.tls // ."delivery-status".tls // "?")"
' /tmp/mg_delivered.json

echo ""
echo "Oldest in sample: $(jq -r '[.items[]."@timestamp"] | last // "N/A"' /tmp/mg_delivered.json)"
echo "Newest in sample: $(jq -r '[.items[]."@timestamp"] | first // "N/A"' /tmp/mg_delivered.json)"

jq '[.items[] | {
  timestamp: ."@timestamp",
  from: .message.headers.from,
  to: (.message.headers.to // .recipient),
  subject: .message.headers.subject,
  mx_host: (."delivery-status"."mx-host" // null),
  tls: (."delivery-status".tls // null),
  sending_ip: .envelope."sending-ip"
}]' /tmp/mg_delivered.json >"$OUT"
cat "$OUT"
