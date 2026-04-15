#!/usr/bin/env bash
# Compare bounce and complaint ratios to thresholds using the Analytics Metrics API.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_STATS_WINDOW_HOURS:-24}"
: "${MAILGUN_MAX_BOUNCE_RATE_PCT:-5}"
: "${MAILGUN_MAX_COMPLAINT_RATE_PCT:-0.1}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_bounce_complaint_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

dur_h="${MAILGUN_STATS_WINDOW_HOURS}"
url="${MG_BASE}/v1/analytics/metrics"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  --arg dur "${dur_h}h" \
  '{
    duration: $dur,
    metrics: ["accepted_outgoing_count", "bounced_count", "complained_count"],
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    include_aggregates: true
  }')

http_code=$(curl -sS --max-time 90 \
  -o /tmp/mg_bc.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_bc.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun metrics API error for bounce/complaint check on \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code}. ${body:0:400}" \
    --argjson severity 3 \
    --arg next_steps "Verify API access and region; retry with backoff." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

accepted=$(jq -r '.aggregates.metrics.accepted_outgoing_count // 0' /tmp/mg_bc.json)
bounce_like=$(jq -r '.aggregates.metrics.bounced_count // 0' /tmp/mg_bc.json)
complained=$(jq -r '.aggregates.metrics.complained_count // 0' /tmp/mg_bc.json)

denom=$accepted
if [[ "$denom" -eq 0 ]]; then denom=1; fi

bounce_pct=$(awk -v b="$bounce_like" -v d="$denom" 'BEGIN { printf "%.6f", (100.0 * b / d) }')
complaint_pct=$(awk -v c="$complained" -v d="$denom" 'BEGIN { printf "%.6f", (100.0 * c / d) }')

max_b="${MAILGUN_MAX_BOUNCE_RATE_PCT}"
max_c="${MAILGUN_MAX_COMPLAINT_RATE_PCT}"

echo "Window: ${dur_h}h | Accepted: ${accepted}, Bounced: ${bounce_like} (${bounce_pct}%, max ${max_b}%), Complaints: ${complained} (${complaint_pct}%, max ${max_c}%)"

if awk -v p="$bounce_pct" -v m="$max_b" 'BEGIN { exit !(p + 0 > m + 0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Elevated Mailgun bounce rate for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Window ${dur_h}h. Approx. bounce count (permanent.bounce sum): ${bounce_like}, accepted (denominator): ${accepted}. Rate ${bounce_pct}% (max ${max_b}%)." \
    --argjson severity 3 \
    --arg next_steps "Review list hygiene, validation, and suppression; inspect Mailgun bounce events and DNS alignment." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

if awk -v p="$complaint_pct" -v m="$max_c" 'BEGIN { exit !(p + 0 > m + 0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Elevated Mailgun complaint rate for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "Window ${dur_h}h. Complained events (summed): ${complained}, accepted (denominator): ${accepted}. Rate ${complaint_pct}% (max ${max_c}%)." \
    --argjson severity 4 \
    --arg next_steps "Pause risky sends; confirm opt-in and content; review complaints in Mailgun and consider list cleaning." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUT"
cat "$OUT"
