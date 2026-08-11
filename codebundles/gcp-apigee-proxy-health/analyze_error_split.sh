#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# analyze_error_split.sh
# Queries the Apigee Analytics stats endpoint (dimension apiproxy) for
# sum(is_error), sum(policy_error), sum(target_error), sum(message_count).
# Flags proxies whose policy_error rate and target_error rate each exceed their
# OWN threshold, TRACKED SEPARATELY because they route to different owners:
#   * policy_error  - fault inside the proxy policy chain (OAuth, KVM, callout,
#                     quota) -> proxy owner
#   * target_error  - backend failed -> hand off to the backend bundle
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          - GCP project owning the Apigee org
#   APIGEE_ORG              - optional; Apigee org (resolved if empty)
#   POLICY_ERROR_THRESHOLD  - max policy_error rate (default 0.01)
#   TARGET_ERROR_THRESHOLD  - max target_error rate (default 0.01)
#   ANALYTICS_WINDOW_MIN    - lookback window in minutes (default 60)
#   PROXIES                 - optional proxy filter ("All" = all)
#
# OUTPUTS:
#   error_split_issues.json - JSON array of issues
#
# NOTE: Analytics data lags real time (~10 min) and the stats endpoint is slow;
# this is a diagnostic signal, not a fast SLI source.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
POLICY_ERROR_THRESHOLD="${POLICY_ERROR_THRESHOLD:-0.01}"
TARGET_ERROR_THRESHOLD="${TARGET_ERROR_THRESHOLD:-0.01}"
ANALYTICS_WINDOW_MIN="${ANALYTICS_WINDOW_MIN:-60}"
PROXIES="${PROXIES:-All}"
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="error_split_issues.json"
apigee_init_issues "$ISSUES_FILE"
apigee_reset_api_errors
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping error split analysis (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

# Analytics time range format: MM/DD/YYYY HH:MM (GMT)
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing policy_error vs target_error split for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, policy>${POLICY_ERROR_THRESHOLD}, target>${TARGET_ERROR_THRESHOLD})"

pair_query="sum(message_count),sum(is_error),sum(policy_error),sum(target_error)"
proxy_filter="$(apigee_expand_csv "$PROXIES")"

environments=$(apigee_list_environments "$ORG")
env_count=$(echo "$environments" | jq length)
if [ "$env_count" -eq 0 ]; then
    echo "No environments resolved for org '$ORG'; cannot analyze Analytics."
    issues_json=$(apigee_append_api_error_issue "$issues_json" "the policy_error vs target_error analysis")
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi
echo "  Environments in scope: $(echo "$environments" | jq -r 'join(", ")')"

dimension_count=0
dimension_count=0
policy_list=""; policy_n=0
target_list=""; target_n=0

for env in $(echo "$environments" | jq -r '.[]'); do
    echo "  Querying stats for environment '$env'..."
    resp=$(apigee_stats "$ORG" "$env" "apiproxy" "$pair_query" "$t_start" "$t_end")
    dims=$(printf '%s' "$resp" | apigee_stats_dimensions)

    # Process substitution, not a pipe: on the right of a pipe this loop runs in
    # a subshell, and every list appended there is discarded when it exits --
    # silently, once per environment.
    while read -r dim; do
        proxy=$(apigee_dimension_part "$dim" 0)
        [ -z "$proxy" ] && continue
        if [ "$proxy_filter" != "All" ]; then
            echo "$proxy_filter" | tr ',' '\n' | grep -qxF "$proxy" || continue
        fi

        dimension_count=$(( dimension_count + 1 ))

        msg_count=$(apigee_metric "$dim" "message_count" sum)
        policy_err=$(apigee_metric "$dim" "policy_error" sum)
        target_err=$(apigee_metric "$dim" "target_error" sum)

        if [ "$(awk -v m="$msg_count" 'BEGIN { print (m > 0) ? 1 : 0 }')" != "1" ]; then
            echo "    Proxy '$proxy': no traffic in window."
            continue
        fi

        policy_rate=$(awk -v e="$policy_err" -v t="$msg_count" 'BEGIN { printf "%.6f", e/t }')
        target_rate=$(awk -v e="$target_err" -v t="$msg_count" 'BEGIN { printf "%.6f", e/t }')
        echo "    Proxy '$proxy': policy_error=$policy_err ($policy_rate) target_error=$target_err ($target_rate) msgs=$msg_count"

        if [ "$(awk -v r="$policy_rate" -v thr="$POLICY_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
            policy_list="${policy_list}  - ${proxy} (env ${env}): rate ${policy_rate} (${policy_err} policy errors / ${msg_count} requests)"$'\n'
            policy_n=$((policy_n + 1))
        fi

        if [ "$(awk -v r="$target_rate" -v thr="$TARGET_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
            target_list="${target_list}  - ${proxy} (env ${env}): rate ${target_rate} (${target_err} target errors / ${msg_count} requests)"$'\n'
            target_n=$((target_n + 1))
        fi
    done < <(printf '%s' "$dims" | jq -c '.[]')
done

if [ "$dimension_count" -eq 0 ]; then
    echo "No proxies returned metrics data in the lookback window (analytics may be empty or lagging)."
fi

# policy_error and target_error are raised SEPARATELY because they route to
# different owners -- the proxy team and the backend team -- which is the whole
# point of splitting them. Within each, all affected proxies are one issue.
if [ "$policy_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have an elevated policy_error rate in \`$GCP_PROJECT_ID\`" 3 \
        "policy_error rate should remain below POLICY_ERROR_THRESHOLD" \
        "$policy_n proxy/environment pair(s) exceed the policy_error threshold" \
        "This is a PROXY problem, not a backend problem: the fault is inside Apigee's policy chain (OAuth, KVM, callout, quota, spike arrest). Inspect fault codes, token validation, API product / developer app mapping, KVM lookups and callout policies for the proxies listed, via Analytics (dimension fault_codes) and message logging." \
        "Threshold: $POLICY_ERROR_THRESHOLD over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$policy_n over threshold:"$'\n'"$policy_list")" '. += [$i]')
fi

if [ "$target_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have an elevated target_error rate in \`$GCP_PROJECT_ID\`" 3 \
        "target_error rate should remain below TARGET_ERROR_THRESHOLD" \
        "$target_n proxy/environment pair(s) exceed the target_error threshold" \
        "The fault is at the BACKEND, not in the proxy. Hand off to the backend bundle (e.g. gcp-cloud-run-service-health or gcp-cloud-loadbalancer-health) and check the target server / backend service health for the proxies listed." \
        "Threshold: $TARGET_ERROR_THRESHOLD over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$target_n over threshold:"$'\n'"$target_list")" '. += [$i]')
fi

issues_json=$(apigee_append_api_error_issue "$issues_json" "the policy_error vs target_error analysis")
echo "$issues_json" > "$ISSUES_FILE"
echo "Error split analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
