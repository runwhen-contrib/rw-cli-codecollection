#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_failed_operations.sh
# Lists long-running operations (deployment, environment change, or instance
# operation) and flags any that completed with an error, so failed management
# operations are surfaced.
#
# NO TIME WINDOW IS APPLIED, deliberately. Neither GoogleLongrunningOperation
# (error, metadata, name, done, response) nor GoogleCloudApigeeV1OperationMetadata
# (targetResourceName, state, warnings, operationType, progress) carries a
# timestamp, and the operation name is a plain UUID. There is nothing to filter
# on, so every failed operation the API still returns is reported rather than
# claiming a lookback the data cannot support. Apigee ages operations out on its
# own schedule, which is what bounds this list.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project owning the Apigee org
#   APIGEE_ORG                - optional; Apigee org (resolved if empty)
#
# OUTPUTS:
#   failed_operations_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="failed_operations_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping failed operations check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

echo "Checking long-running operations for org: $ORG"

ops=$(apigee_list_operations "$ORG")
total=$(echo "$ops" | jq length)
echo "  Retrieved $total operation(s)."

while read -r op; do
    name=$(echo "$op" | jq -r '.name // "unknown"')
    err_code=$(echo "$op" | jq -r '.error.code // "unknown"')
    err_msg=$(echo "$op" | jq -r '.error.message // "unknown"')
    op_type=$(echo "$op" | jq -r '.metadata.operationType // "unknown"')
    target=$(echo "$op" | jq -r '.metadata.targetResourceName // "unknown"')
    echo "  FAILED operation: $name (code=$err_code)"
    issue=$(jq -n \
        --arg title "Failed long-running operation in Apigee org \`$ORG\`" \
        --arg details "Operation '$name' (type $op_type, target $target) completed with an error: code=$err_code message=$err_msg. Apigee's operations API exposes no timestamps, so this finding is not time-bounded." \
        --arg severity "2" \
        --arg expected "Management operations (deployments, environment changes, instance changes) should complete without error" \
        --arg actual "Operation '$name' failed: $err_msg" \
        --arg next_steps "Inspect the failed operation '$name' in GCP Operations / Apigee monitoring. If it was a proxy deployment, redeploy the affected revision; if an environment or instance change, review the operation metadata for the cause." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
done < <(echo "$ops" | jq -c '.[] | select((.done == true) and (has("error")))')

echo "$issues_json" > "$ISSUES_FILE"
echo "Failed operations check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
