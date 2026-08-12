#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_deployment_state.sh
# For each proxy deployment, verifies the runtime state is READY (deployed)
# with an empty errors[] array. Flags any deployment in ERROR/PROGRESSING state
# or with non-empty errors[], which means the deploy did not fully take effect.
#
# Runtime state comes from the deployment STATUS view, merged onto each
# deployment by discover_proxies.sh. Deployments whose status could not be read
# carry state UNKNOWN and are reported as such -- never as healthy.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID     - GCP project owning the Apigee org
#   APIGEE_ORG         - optional; Apigee org (resolved if empty)
#
# OUTPUTS:
#   deployment_state_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="deployment_state_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

# Discovery runs in Suite Initialization and fails the suite when it could not
# build an inventory, so by the time this runs the topology is guaranteed to
# exist. A missing one means something is genuinely wrong -- reading it as an
# empty estate here would report "no issues found" for a check that never
# looked at anything.
if [ ! -f "$APIGEE_TOPOLOGY_FILE" ]; then
    echo "ERROR: $APIGEE_TOPOLOGY_FILE is missing. Discovery runs in Suite Initialization;" >&2
    echo "       run discover_proxies.sh first if you are invoking this script directly." >&2
    exit 1
fi

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping deployment state check (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

deployments=$(apigee_load_deployments)
total=$(echo "$deployments" | jq length)
echo "Checking deployment state for $total deployment(s) in org: $ORG"

# An empty org produces zero issues from every check. Say so in the report so a
# clean result is not mistaken for a verified one.
if [ "$total" -eq 0 ]; then
    echo "No deployments in scope; there is no deployment state to judge."
fi

# Process substitution, not a pipe: a `while read` on the right of a pipe runs
# Findings are COLLECTED per condition, then raised as one issue each. The SLX
# is project-scoped, so one issue per affected proxy would split a single class
# of problem across N issues and churn as proxies break and heal.
err_list=""     ; err_n=0
prog_list=""    ; prog_n=0
unk_list=""     ; unk_n=0
soft_list=""    ; soft_n=0

# Process substitution, not a pipe: a `while read` on the right of a pipe runs
# in a subshell and every list appended there is discarded when it exits.
while read -r dep; do
    proxy=$(echo "$dep" | jq -r '.apiProxy // "unknown"')
    env=$(echo "$dep" | jq -r '.environment // "unknown"')
    revision=$(echo "$dep" | jq -r '.revision // "unknown"')
    state=$(echo "$dep" | jq -r '.state // "UNKNOWN"')
    errors=$(echo "$dep" | jq -c '.errors // []')

    echo -n "  $proxy ($env rev $revision): state=$state"

    case "$state" in
        ERROR)
            echo " -> ERROR"
            err_list="${err_list}  - ${proxy} (env ${env}, revision ${revision}): ${errors}"$'\n'
            err_n=$((err_n + 1))
            continue
            ;;
        PROGRESSING)
            echo " -> PROGRESSING"
            prog_list="${prog_list}  - ${proxy} (env ${env}, revision ${revision})"$'\n'
            prog_n=$((prog_n + 1))
            continue
            ;;
        UNKNOWN)
            echo " -> status unavailable"
            reason=$(echo "$dep" | jq -r '.statusSkippedReason // "unknown"')
            unk_list="${unk_list}  - ${proxy} (env ${env}, revision ${revision}): ${reason}"$'\n'
            unk_n=$((unk_n + 1))
            continue
            ;;
    esac

    if [ "$errors" != "[]" ] && [ -n "$errors" ]; then
        echo " -> errors[] present"
        soft_list="${soft_list}  - ${proxy} (env ${env}, revision ${revision}): ${errors}"$'\n'
        soft_n=$((soft_n + 1))
        continue
    fi

    echo " -> OK"
done < <(echo "$deployments" | jq -c '.[]')

if [ "$err_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxy deployments are in ERROR state in org \`$ORG\`" 2 \
        "Every proxy deployment should be READY with an empty errors[] array" \
        "$err_n deployment(s) are in ERROR state" \
        "The deploy did not take effect for the deployments listed in the details. Redeploy the affected revision to its environment, or investigate the reported error(s). See https://cloud.google.com/apigee/docs/api-platform/deploy/deploy-api-proxy." \
        "$err_n deployment(s) in ERROR state:"$'\n'"$err_list")" '. += [$i]')
fi

if [ "$prog_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxy deployments are stuck PROGRESSING in org \`$ORG\`" 2 \
        "Every proxy deployment should reach READY" \
        "$prog_n deployment(s) are still PROGRESSING" \
        "Wait for these deployments to reach READY. If they stay PROGRESSING, redeploy the affected revision or check runtime health." \
        "$prog_n deployment(s) still PROGRESSING:"$'\n'"$prog_list")" '. += [$i]')
fi

if [ "$unk_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee deployment runtime status could not be read in org \`$ORG\`" 3 \
        "The deployment status view should report a runtime state for every deployment" \
        "$unk_n deployment(s) have an unreadable runtime state" \
        "Confirm the service account holds roles/apigee.readOnlyAdmin, check APIGEE_MAX_STATUS_CALLS is not capping this org, then re-run discovery. These deployments are UNKNOWN, not healthy." \
        "$unk_n deployment(s) with unreadable status:"$'\n'"$unk_list")" '. += [$i]')
fi

if [ "$soft_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxy deployments are reporting errors in org \`$ORG\`" 2 \
        "A deployment reported as serving should have an empty errors[] array" \
        "$soft_n deployment(s) report errors despite not being in ERROR state" \
        "Investigate the reported errors: these proxies may be degraded though the deployment is not in ERROR state." \
        "$soft_n deployment(s) reporting errors:"$'\n'"$soft_list")" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Deployment state check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
