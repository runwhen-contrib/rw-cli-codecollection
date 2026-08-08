#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_failed_operations.sh
# Lists long-running operations in the lookback window and flags any that
# failed (deployment, environment change, or instance operation that errored)
# so failed management operations are surfaced.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project owning the Apigee org
#   APIGEE_ORG                - optional; Apigee org (resolved if empty)
#   OPERATIONS_LOOKBACK_HOURS - lookback window in hours (default 24)
#
# OUTPUTS:
#   failed_operations_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
OPERATIONS_LOOKBACK_HOURS="${OPERATIONS_LOOKBACK_HOURS:-24}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="failed_operations_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping failed operations check."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

# Long-running operation names embed the creation time as "operations/{uuid}".
# Recent operations are the ones we care about; list all and filter by the
# operation's own metadata createTime where present, else by name timestamp.
cutoff_hours=$(( OPERATIONS_LOOKBACK_HOURS ))
echo "Checking long-running operations for org: $ORG (lookback: ${OPERATIONS_LOOKBACK_HOURS}h)"

now_epoch=$(date +%s)
cutoff_epoch=$(( now_epoch - (cutoff_hours * 3600) ))

ops=$(apigee_list_operations "$ORG")
total=$(echo "$ops" | jq length)
echo "  Retrieved $total operation(s)."

echo "$ops" | jq -c '.[]' | while read -r op; do
    name=$(echo "$op" | jq -r '.name // "unknown"')
    done_flag=$(echo "$op" | jq -r '.done // false')
    has_error=$(echo "$op" | jq -r 'has("error") // false')

    # Try to extract timestamp from operation name (uuid encodes epoch ms).
    op_epoch=0
    if echo "$name" | grep -qE '[0-9]{13}'; then
        op_epoch=$(echo "$name" | grep -oE '[0-9]{13}' | head -n1 | cut -c1-10)
    else
        # Fall back to metadata createTime if present (seconds since epoch).
        meta_ts=$(echo "$op" | jq -r '.metadata.createTime // ""' 2>/dev/null)
        if [ -n "$meta_ts" ] && [ "$meta_ts" != "null" ]; then
            op_epoch=$(date -u -d "$(echo "$meta_ts" | tr 'T' ' ' | cut -d. -f1 | sed 's/Z$//')" "+%s" 2>/dev/null || echo 0)
        fi
    fi

    if [ "$done_flag" = "true" ] && [ "$has_error" = "true" ]; then
        # Consider it in the window if we have a timestamp, or always if none.
        if [ "$op_epoch" = "0" ] || [ "$op_epoch" -ge "$cutoff_epoch" ]; then
            err_code=$(echo "$op" | jq -r '.error.code // "unknown"')
            err_msg=$(echo "$op" | jq -r '.error.message // "unknown"')
            echo "  FAILED operation: $name (code=$err_code)"
            issue=$(jq -n \
                --arg title "Failed long-running operation in Apigee org \`$ORG\`" \
                --arg details "Operation '$name' failed within the last ${OPERATIONS_LOOKBACK_HOURS}h. error: code=$err_code message=$err_msg" \
                --arg severity "2" \
                --arg expected "Management operations (deployments, environment changes, instance changes) should complete without error" \
                --arg actual "Operation '$name' failed: $err_msg" \
                --arg next_steps "Inspect the failed operation '$name' in GCP Operations / Apigee monitoring. If it was a proxy deployment, redeploy the affected revision; if an environment or instance change, review the operation metadata for the cause." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        fi
    fi
done

echo "  Retrieved $total operation(s); checked failures in the ${OPERATIONS_LOOKBACK_HOURS}h window."

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Failed operations check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
