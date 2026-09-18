#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#
# This script checks that configured Log Streams are enabled and delivering
# (no backlog/failure states) so that log-based monitoring and retention
# accurately reflect tenant activity. It raises issues for disabled or failing
# log streams.
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

OUTPUT_FILE="log_stream_issues.json"
issues_json='[]'

echo "Verifying log stream delivery health for tenant: ${AUTH0_TENANT}"

streams_raw="$(auth0_get "$(auth0_mgmt_url "log-streams")" || echo '[]')"

if ! echo "${streams_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Unable to list log streams (non-array response). Scope may be missing (read:log_streams)."
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

stream_count="$(echo "${streams_raw}" | jq 'length')"
echo "Configured log streams: ${stream_count}"

if [ "${stream_count}" -eq 0 ]; then
    echo "No log streams configured for tenant ${AUTH0_TENANT}. Log-based monitoring may have no data source."
    issues_json=$(echo "${issues_json}" | jq \
        --arg tenant "${AUTH0_TENANT}" \
        --arg title "No Auth0 Log Streams Configured for \`${AUTH0_TENANT}\`" \
        --arg details "No Log Streams found for tenant ${AUTH0_TENANT}. Without a stream, logs may only exist via the Logs API (retention-limited)." \
        --argjson severity 2 \
        --arg next_steps "Consider configuring a Log Stream in the Auth0 dashboard to send events to a SIEM/observability sink." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

while IFS= read -r stream; do
    [ -z "${stream}" ] && continue
    id="$(echo "${stream}" | jq -r '.id // empty')"
    name="$(echo "${stream}" | jq -r '.name // empty')"
    stype="$(echo "${stream}" | jq -r '.type // "unknown"')"
    status="$(echo "${stream}" | jq -r '.status // "empty"')"

    echo "Checking log stream: ${name} (id: ${id}, type: ${stype}, status: ${status})"

    # Auth0 log stream status values: 'active', 'paused', 'suspended', 'empty'
    if [ "${status}" != "active" ] && [ "${status}" != "empty" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg name "${name}" \
            --arg st "${status}" \
            --arg tenant "${AUTH0_TENANT}" \
            --arg title "Auth0 Log Stream Not Active for \`${name}\`" \
            --arg details "Log stream '${name}' (id: ${id}) on tenant ${AUTH0_TENANT} has status '${status}'. Expected 'active'." \
            --argjson severity 2 \
            --arg next_steps "Re-enable the log stream in the Auth0 dashboard; if suspended, investigate why delivery was paused." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    fi
done < <(echo "${streams_raw}" | jq -c '.[]')

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Log stream delivery health check completed. Results saved to ${OUTPUT_FILE}"