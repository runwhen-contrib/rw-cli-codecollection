#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Unauthenticated probe of the EU Mailgun API base (api.eu.mailgun.net).
# Expects HTTP 401 with JSON when no API key is supplied.
# Env: MAILGUN_STATUS_REGION_FOCUS — skip when set to "us" only.
# -----------------------------------------------------------------------------

OUTPUT_FILE="${OUTPUT_FILE:-api_eu_reachability_output.json}"
MAILGUN_STATUS_REGION_FOCUS="${MAILGUN_STATUS_REGION_FOCUS:-both}"
API_URL="https://api.eu.mailgun.net/v3/domains"

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

if [[ "$MAILGUN_STATUS_REGION_FOCUS" == "us" ]]; then
  echo '[]' | jq '.' >"$OUTPUT_FILE"
  echo "Skipped EU API check (MAILGUN_STATUS_REGION_FOCUS=${MAILGUN_STATUS_REGION_FOCUS})"
  exit 0
fi

tmp_body=$(mktemp)
http_code="000"
set +e
http_code=$(curl -sS -o "$tmp_body" -w '%{http_code}' --connect-timeout 10 --max-time 60 \
  -H 'Accept: application/json' "$API_URL")
curl_rc=$?
set -e

body_head=$(head -c 400 "$tmp_body" | tr -d '\r' || true)
rm -f "$tmp_body"

if [[ "$curl_rc" -ne 0 ]]; then
  append_issue \
    "Mailgun EU API base unreachable (TLS or network failure)" \
    "curl completes with exit 0 and an HTTP status from Mailgun" \
    "curl exit ${curl_rc} for ${API_URL}" \
    "curl to ${API_URL} failed before a reliable HTTP status was recorded." \
    4 \
    "Check egress to the EU region, DNS for api.eu.mailgun.net, and Mailgun status before debugging domain configuration."
elif [[ "$http_code" == "000" ]]; then
  append_issue \
    "Mailgun EU API base returned no HTTP status" \
    "curl returns a non-zero HTTP status code" \
    "Recorded HTTP code ${http_code}" \
    "curl completed without a usable HTTP code for ${API_URL}." \
    4 \
    "Investigate network path; compare with US reachability and the public status page."
elif [[ "$http_code" != "401" ]]; then
  append_issue \
    "Mailgun EU API base returned unexpected HTTP ${http_code}" \
    "Unauthenticated GET returns HTTP 401 with JSON from Mailgun" \
    "HTTP ${http_code}; body prefix: ${body_head}" \
    "Expected HTTP 401 for unauthenticated GET ${API_URL}." \
    4 \
    "Compare with documented API behavior; verify you require EU routing and that proxies are not altering responses."
else
  if ! echo "$body_head" | jq -e . >/dev/null 2>&1; then
    append_issue \
      "Mailgun EU API base response was not JSON" \
      "HTTP 401 body parses as JSON" \
      "Non-JSON body prefix: ${body_head}" \
      "HTTP ${http_code} received but body did not parse as JSON." \
      3 \
      "Validate that traffic reaches Mailgun EU and is not rewritten by a proxy or HTML error page."
  fi
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))"
