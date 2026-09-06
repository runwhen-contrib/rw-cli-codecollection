#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#   LOG_LOOKBACK_HOURS          (default 24)
#   LOGIN_FAILURE_THRESHOLD     (default 50)
#
# This script detects elevated login-failure and fraud/hack attempts from the
# log stream (blocked users, brute-force patterns, passwordless failures) and
# reports per-connection anomalies against a configurable threshold.
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

: "${LOG_LOOKBACK_HOURS:=24}"
: "${LOGIN_FAILURE_THRESHOLD:=50}"

OUTPUT_FILE="login_failure_issues.json"
issues_json='[]'

echo "Checking login failures and anomalous activity for tenant: ${AUTH0_TENANT} (threshold: ${LOGIN_FAILURE_THRESHOLD})"

from_ts="$(date -u -d "${LOG_LOOKBACK_HOURS} hours ago" +%Y%m%dT%H%M%S00Z 2>/dev/null || echo "19700101T000000Z")"

# Use jq / Logs API query syntax to count failed logins of all failure types
# f = failed login, fcoa = failed cross-origin auth, fwd = failed with reused
# password, fle = failed login enum probe, fpwd = failed password change.
logs_raw="$(auth0_get "$(auth0_mgmt_url "logs")" \
    "sort=date:desc" \
    "per_page=100" \
    "q=type:f OR type:fcoa OR type:fwd OR type:fle OR type:fpwd AND date:[${from_ts} TO NOW]" \
    || echo '[]')"

if ! echo "${logs_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Unable to retrieve login failure logs (non-array response)."
    echo "[]" > "${OUTPUT_FILE}"
    exit 0
fi

failed_logins="$(echo "${logs_raw}" | jq '[.[] | select(.type_name | test("fail|forgot|invalid|block"; "i"))] | length' 2>/dev/null || echo 0)"

echo "Failed-login / anomalous events in lookback window: ${failed_logins}"

# -- Blocked users / brute force or fraud signals --
blocked_users="$(echo "${logs_raw}" | jq -r '[.[] | select((.user_id // "") != "" and (.type_name | test("block|limit|brute|fraud"; "i")))] | .[] | .user_id' 2>/dev/null || true)"
blocked_count=$( [ -n "${blocked_users}" ] && echo "${blocked_users}" | grep -c . || echo 0 )

if [ -n "${blocked_users}" ]; then
    echo "Blocked/flagged user IDs:"
    echo "${blocked_users}"
fi

# -- Per-connection anomaly breakdown --
connection_buckets="$(echo "${logs_raw}" | jq -c '
    reduce .[]? as $l ({}; .[$l.connection // "unknown"] += 1)
    ' 2>/dev/null || echo '{}')"

echo "=== FAILED-LOGIN BY CONNECTION ==="
if [ -n "${connection_buckets}" ] && [ "${connection_buckets}" != "{}" ]; then
    echo "${connection_buckets}" | jq '.'
fi

# -- Aggregate threshold check --
if [ "${failed_logins}" -ge "${LOGIN_FAILURE_THRESHOLD}" ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg tl "${failed_logins}" \
        --arg thr "${LOGIN_FAILURE_THRESHOLD}" \
        --arg tenant "${AUTH0_TENANT}" \
        --arg title "Elevated Login Failures for Tenant \`${AUTH0_TENANT}\`" \
        --arg details "${failed_logins} failed/login-anomaly events detected in the last ${LOG_LOOKBACK_HOURS}h. Threshold: ${LOGIN_FAILURE_THRESHOLD}." \
        --argjson severity 3 \
        --arg next_steps "Investigate for brute-force or credential-stuffing activity. Consider enabling/raising Auth0 Anomaly Detection (brute force protection, bot detection) and reviewing blocked users." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

if [ "${blocked_count}" -gt 0 ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg bc "${blocked_count}" \
        --arg tenant "${AUTH0_TENANT}" \
        --arg title "Blocked or Flagged Users Detected for Tenant \`${AUTH0_TENANT}\`" \
        --arg details "Anomaly Detection flagged ${blocked_count} user(s) for brute-force/fraud behavior in the lookback window." \
        --argjson severity 2 \
        --arg next_steps "Review the flagged users, distinguish legitimate access from attacks, and take appropriate action (unblock or enforce MFA)." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Login failure analysis completed. Results saved to ${OUTPUT_FILE}"