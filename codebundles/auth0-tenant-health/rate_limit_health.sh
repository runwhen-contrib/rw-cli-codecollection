#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#   LOG_LOOKBACK_HOURS          (default 24)
#   RATE_LIMIT_THRESHOLD_PCT    (default 80)
#
# This script monitors the tenant for rate-limit events and 429 responses
# across the Management API and authentication traffic. It raises issues when
# rate-limit utilization approaches checkpoint limits or sustained throttling
# is observed.
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

: "${LOG_LOOKBACK_HOURS:=24}"
: "${RATE_LIMIT_THRESHOLD_PCT:=80}"

OUTPUT_FILE="rate_limit_issues.json"
issues_json='[]'

echo "Checking rate limit / throttling signals for tenant: ${AUTH0_TENANT} (threshold pct: ${RATE_LIMIT_THRESHOLD_PCT})"

# --- Management API rate limit utilization ---
# Capture rate-limit headers from a Management API call.
curl -sS -D /tmp/auth0_rate_headers.txt -o /tmp/auth0_rate_body.json --max-time 30 \
    -H "Authorization: Bearer ${AUTH0_MGMT_TOKEN}" \
    -H "Accept: application/json" \
    "$(auth0_mgmt_url "tenant" "settings")" || true

rate_limit="$(grep -i '^X-RateLimit-Limit:' /tmp/auth0_rate_headers.txt 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo '')"
rate_remaining="$(grep -i '^X-RateLimit-Remaining:' /tmp/auth0_rate_headers.txt 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo '')"
rate_reset="$(grep -i '^X-RateLimit-Reset:' /tmp/auth0_rate_headers.txt 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo '')"

echo "Management API rate limit: ${rate_limit:-unknown}, remaining: ${rate_remaining:-unknown}"

if [ -n "${rate_limit}" ] && [ -n "${rate_remaining}" ] && [ "${rate_limit}" -gt 0 ]; then
    used=$(( rate_limit - rate_remaining ))
    pct=$(( used * 100 / rate_limit ))
    echo "Management API rate limit utilization: ${pct}% (used ${used}/${rate_limit})"
    if [ "${pct}" -ge "${RATE_LIMIT_THRESHOLD_PCT}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg pct "${pct}" \
            --arg thr "${RATE_LIMIT_THRESHOLD_PCT}" \
            --arg tenant "${AUTH0_TENANT}" \
            --arg title "Management API Rate Limit Utilization High for \`${AUTH0_TENANT}\`" \
            --arg details "Management API rate-limit utilization is ${pct}% (used ${used}/${rate_limit}). Threshold: ${RATE_LIMIT_THRESHOLD_PCT}%." \
            --argjson severity 2 \
            --arg next_steps "Reduce Management API call frequency, use caching, or request a higher rate limit tier from Auth0." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    fi
fi

# --- Sustained throttling signals from logs (limit / 429 events) ---
from_ts="$(date -u -d "${LOG_LOOKBACK_HOURS} hours ago" +%Y%m%dT%H%M%S00Z 2>/dev/null || echo "19700101T000000Z")"
limit_logs="$(auth0_get "$(auth0_mgmt_url "logs")" \
    "sort=date:desc" \
    "per_page=100" \
    "q=type.limit OR type:limitw AND date:[${from_ts} TO NOW]" \
    || echo '[]')"

limit_count="0"
if echo "${limit_logs}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    limit_count="$(echo "${limit_logs}" | jq 'length')"
fi
echo "Rate-limit / throttling log events in lookback window: ${limit_count}"

if [ "${limit_count}" -gt 0 ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg lc "${limit_count}" \
        --arg tenant "${AUTH0_TENANT}" \
        --arg title "Auth0 Rate Limit Events Detected for \`${AUTH0_TENANT}\`" \
        --arg details "${limit_count} rate-limit/throttling (limit/429) event(s) detected in the last ${LOG_LOOKBACK_HOURS}h for tenant ${AUTH0_TENANT}." \
        --argjson severity 3 \
        --arg next_steps "Check which endpoint is being throttled, back off retries, and review token/service usage. Consult Auth0 rate limit documentation for the tenant tier." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

rm -f /tmp/auth0_rate_headers.txt /tmp/auth0_rate_body.json || true

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Rate limit health check completed. Results saved to ${OUTPUT_FILE}"