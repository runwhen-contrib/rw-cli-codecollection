#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#   LOG_LOOKBACK_HOURS    (default 24)
#
# This script pulls recent log events from the Auth0 Logs API, buckets them by
# type, and flags error, warn, and anomaly event classes (authentication
# failures, failed account linking, MFA errors, etc.) within the lookback
# window. It emits issues for spikes or repeated error types.
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

: "${LOG_LOOKBACK_HOURS:=24}"

OUTPUT_FILE="error_logs_issues.json"
issues_json='[]'

echo "Analyzing tenant error logs for tenant: ${AUTH0_TENANT} (lookback: ${LOG_LOOKBACK_HOURS}h)"

from_ts="$(date -u -d "${LOG_LOOKBACK_HOURS} hours ago" +%Y%m%dT%H%M%S00Z 2>/dev/null || echo "19700101T000000Z")"

# Error/warn/anomaly Auth0 log type codes (numeric) commonly indicating problems.
# Reference: https://auth0.com/docs/deploy-monitor/logs/log-event-type-codes
# 'f' = failed, 's' = success. We focus on failure/anomaly classes.
error_types='f|fa|flt|fcoa|fcu|fco|fcpr|fcp|fcph|fcn|fcpe|fde|fdu|fede|fdlr|fda|fd|fdc|feca|fec|fep|fe|ff|fo|fn|fop|foph|fopsa|fopra|fopf|fop3sa|fopq|fopc|fpe|fpea|fpwd|fws|fwd|fwe|fwm|fwds|c|cp|dv|errt|limit|limitw|sdp|u|ul|ulc|u2|ud|u2d|un|u2qm|u2p|u2q|u2r|mfa|mfar|mlt|ratio|vq|auth0-anomaly|block'

logs_raw="$(auth0_get "$(auth0_mgmt_url "logs")" \
    "sort=date:desc" \
    "per_page=100" \
    "q=date:[${from_ts} TO NOW]" \
    || echo '[]')"

if ! echo "${logs_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Unable to retrieve logs (non-array response). Check permissions/scope (read:logs)."
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

log_count="$(echo "${logs_raw}" | jq 'length')"
echo "Log events retrieved in lookback window (first 100): ${log_count}"

if [ "${log_count}" -eq 0 ]; then
    echo "No log events found in the lookback window."
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

# Bucket by type + type_name
buckets="$(echo "${logs_raw}" | jq -c '
    reduce .[] as $l ({}; .[$l.type_name // ($l.type | tostring)] += 1)')"

echo "=== LOG TYPE BUCKETS ==="
echo "${buckets}" | jq '.'

# Detect repeated problem types against a small spike threshold (>=3 occurrences)
spike_threshold=3
echo "${buckets}" | jq -r 'to_entries[] | [.key, .value] | @tsv' | while IFS=$'\t' read -r type_code count; do
    if echo "${type_code}" | grep -qE "(^|^f)|failed|failure|error|anomaly|block|mfa" 2>/dev/null || true; then
        case "${type_code}" in
            f|flt|fcoa|fcu|fco|fcpr|fcp|fcph|fpwd|fwd|fwds|fwm|fu|fwe|errt|limit|limitw|block|mfa|mfar|auth0-anomaly)
                echo "Flagging error-type bucket: ${type_code} (count: ${count})"
                ;;
            *)
                continue ;;
        esac
    else
        continue
    fi

    if [ "${count}" -ge "${spike_threshold}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg tc "${type_code}" \
            --arg cnt "${count}" \
            --arg tenant "${AUTH0_TENANT}" \
            --arg title "Repeated Auth0 Error Log Type \`${type_code}\` for \`${AUTH0_TENANT}\`" \
            --arg details "Log type '${type_code}' appeared ${count} time(s) in the last ${LOG_LOOKBACK_HOURS}h lookback window for tenant ${AUTH0_TENANT}. This indicates repeated authentication/security failures." \
            --argjson severity 3 \
            --arg next_steps "Review the authentication traffic for this connector/tenant, check blocked users, and investigate the root cause of the repeated ${type_code} events." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    fi
done

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Error log analysis completed. Results saved to ${OUTPUT_FILE}"