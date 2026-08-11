#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_failed_operations.sh
# Lists long-running operations (deployment, environment change, or instance
# operation) and flags any that completed with an error AND left no trace in
# deployment state -- a failed deploy is reported by check_deployment_state.sh,
# so surfacing it here as well would cost a second triage for one fault.
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

# A failed DEPLOY operation leaves the deployment in ERROR state, which
# check_deployment_state.sh already reports per deployment, naming the proxy and
# environment. Reporting it here too would make an operator triage one fault
# twice. This check owns what only it can see: operations that left no trace in
# deployment state -- environment changes, instance changes, and deploys that
# failed before any deployment record existed.
deployments=$(apigee_load_deployments)

# already_reported <targetResourceName> -> 0 when an ERROR deployment matches
already_reported() {
    local target="$1" env proxy rev
    # .../environments/{env}/apis/{proxy}/revisions/{rev}
    case "$target" in
        */environments/*/apis/*/revisions/*) ;;
        *) return 1 ;;
    esac
    env=${target#*/environments/}; env=${env%%/*}
    proxy=${target#*/apis/};       proxy=${proxy%%/*}
    rev=${target##*/revisions/};   rev=${rev%%/*}
    [ "$(printf '%s' "$deployments" | jq --arg e "$env" --arg p "$proxy" --arg r "$rev" \
        '[.[] | select(.environment == $e and .apiProxy == $p and (.revision|tostring) == $r and .state == "ERROR")] | length')" != "0" ]
}

while read -r op; do
    name=$(echo "$op" | jq -r '.name // "unknown"')
    err_code=$(echo "$op" | jq -r '.error.code // "unknown"')
    err_msg=$(echo "$op" | jq -r '.error.message // "unknown"')
    op_type=$(echo "$op" | jq -r '.metadata.operationType // "unknown"')
    target=$(echo "$op" | jq -r '.metadata.targetResourceName // "unknown"')

    if already_reported "$target"; then
        echo "  FAILED operation: $name -- already reported as an ERROR deployment; skipping"
        continue
    fi

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
