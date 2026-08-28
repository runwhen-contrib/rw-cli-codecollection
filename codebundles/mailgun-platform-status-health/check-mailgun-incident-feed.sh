#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Uses Mailgun Statuspage incidents JSON (public) to highlight major/critical
# incidents that resolved within the lookback window — useful context even when
# the page is green again. Skips active incidents handled by the unresolved API.
# Env: MAILGUN_STATUS_LOOKBACK_HOURS (default 24)
# -----------------------------------------------------------------------------

OUTPUT_FILE="${OUTPUT_FILE:-incident_feed_output.json}"
MAILGUN_STATUS_LOOKBACK_HOURS="${MAILGUN_STATUS_LOOKBACK_HOURS:-24}"
INCIDENTS_URL="https://status.mailgun.com/api/v2/incidents.json"

issues_json='[]'

append_issue() {
  local title="$1"
  local expected="$2"
  local actual="$3"
  local details="$4"
  local severity="$5"
  local next_steps="$6"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, expected: $expected, actual: $actual, details: $details, severity: $severity, next_steps: $next_steps}]')
}

now_epoch=$(date +%s)
cutoff_epoch=$((now_epoch - MAILGUN_STATUS_LOOKBACK_HOURS * 3600))

if ! inc_raw=$(curl -fsS --connect-timeout 10 --max-time 60 "$INCIDENTS_URL" 2>/dev/null); then
  append_issue \
    "Cannot fetch Mailgun incidents feed JSON" \
    "HTTPS GET to incidents.json succeeds" \
    "GET ${INCIDENTS_URL} failed" \
    "Unable to load the incident history feed from Statuspage." \
    3 \
    "Verify outbound HTTPS; use https://status.mailgun.com as a fallback."
else
  count=$(echo "$inc_raw" | jq '.incidents | length')
  idx=0
  while [[ "$idx" -lt "${count:-0}" ]]; do
    inc=$(echo "$inc_raw" | jq -c ".incidents[$idx]")
    impact=$(echo "$inc" | jq -r '.impact // "none"')
    istatus=$(echo "$inc" | jq -r '.status // "unknown"')
    name=$(echo "$inc" | jq -r '.name // "Incident"')
    resolved_at=$(echo "$inc" | jq -r '.resolved_at // empty')
    shortlink=$(echo "$inc" | jq -r '.shortlink // empty')

    if [[ "$impact" != "major" && "$impact" != "critical" ]]; then
      idx=$((idx + 1))
      continue
    fi

    if [[ "$istatus" != "resolved" ]]; then
      idx=$((idx + 1))
      continue
    fi

    if [[ -z "$resolved_at" ]]; then
      idx=$((idx + 1))
      continue
    fi

    res_epoch=$(date -d "$resolved_at" +%s 2>/dev/null || echo 0)
    if [[ "$res_epoch" -lt "$cutoff_epoch" ]]; then
      idx=$((idx + 1))
      continue
    fi

    append_issue \
      "Recent resolved Mailgun ${impact} incident: ${name}" \
      "No major or critical incidents resolved within the configured lookback window" \
      "impact=${impact}; status=${istatus}; resolved_at=${resolved_at}" \
      "Within the last ${MAILGUN_STATUS_LOOKBACK_HOURS}h a ${impact} incident reached resolved state. Link: ${shortlink}" \
      2 \
      "Review post-incident behavior for your integration (retries, queues); confirm metrics and logs look healthy after the window."
    idx=$((idx + 1))
  done
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))"
