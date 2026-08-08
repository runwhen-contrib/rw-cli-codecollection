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
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="error_split_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping error split analysis."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

# Analytics time range format: MM/DD/YYYY HH:MM (GMT)
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing policy_error vs target_error split for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, policy>${POLICY_ERROR_THRESHOLD}, target>${TARGET_ERROR_THRESHOLD})"

metric_count=0
pair_query="sum(message_count),sum(is_error),sum(policy_error),sum(target_error)"

for env in $(apigee_list_environments "$ORG" | jq -r '.[]'); do
    echo "  Querying stats for environment '$env'..."
    # Wrap each metric in its own query group; the select is a comma list.
    resp=$(apigee_stats "$ORG" "$env" "apiproxy" "$pair_query" "$t_start" "$t_end")

    # Each dimension = one proxy. Filter by PROXIES.
    echo "$resp" | jq -c '.environments[0].dimensions // []' | jq -c --arg f "$(apigee_expand_csv "$PROXIES")" '
        .[] |
        if $f == "All" then .
        else select(.name as $n | ($f | split(",")) | index($n))
        end' | while read -r dim; do
            proxy=$(echo "$dim" | jq -r '.name')
            msg_count=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("message_count")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')
            policy_err=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("policy_error")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')
            target_err=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("target_error")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')

            metric_count=$(( metric_count + 1 ))
            [ "$msg_count" = "0" ] || [ -z "$msg_count" ] && { echo "    Proxy '$proxy': no traffic in window."; continue; }

            policy_rate=$(awk -v e="$policy_err" -v t="$msg_count" 'BEGIN { printf "%.6f", e/t }')
            target_rate=$(awk -v e="$target_err" -v t="$msg_count" 'BEGIN { printf "%.6f", e/t }')
            echo "    Proxy '$proxy': policy_error=$policy_err ($policy_rate) target_error=$target_err ($target_rate) msgs=$msg_count"

            if [ "$(awk -v r="$policy_rate" -v thr="$POLICY_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                issue=$(jq -n \
                    --arg title "High policy_error rate for proxy \`$proxy\` (env \`$env\`)" \
                    --arg details "Proxy '$proxy' had a policy_error rate of $policy_rate ($policy_err policy errors / $msg_count requests) in the last ${ANALYTICS_WINDOW_MIN}m, exceeding POLICY_ERROR_THRESHOLD $POLICY_ERROR_THRESHOLD. Fault is INSIDE Apigee's policy chain (OAuth, KVM, callout, quota, spike arrest)." \
                    --arg severity "3" \
                    --arg expected "policy_error rate should remain below $POLICY_ERROR_THRESHOLD" \
                    --arg actual "Proxy '$proxy' policy_error rate is $policy_rate" \
                    --arg next_steps "Own the proxy policy chain: inspect fault codes, OAuth/token validation, API product / developer app mapping, KVM lookups and callout policies for '$proxy' in '$env' via Analytics (dimension fault_codes) and message logging. This is a PROXY problem, not a backend problem." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi

            if [ "$(awk -v r="$target_rate" -v thr="$TARGET_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                issue=$(jq -n \
                    --arg title "High target_error rate for proxy \`$proxy\` (env \`$env\`)" \
                    --arg details "Proxy '$proxy' had a target_error rate of $target_rate ($target_err target errors / $msg_count requests) in the last ${ANALYTICS_WINDOW_MIN}m, exceeding TARGET_ERROR_THRESHOLD $TARGET_ERROR_THRESHOLD. Fault is at the BACKEND." \
                    --arg severity "3" \
                    --arg expected "target_error rate should remain below $TARGET_ERROR_THRESHOLD" \
                    --arg actual "Proxy '$proxy' target_error rate is $target_rate" \
                    --arg next_steps "Hand off to the backend bundle (e.g. gcp-cloud-run-service-health or gcp-cloud-loadbalancer-health): the backend for '$proxy' in '$env' is failing. Check the target server / backend service health, not the proxy policy chain." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi
    done
done

if [ "$metric_count" = "0" ]; then
    echo "No proxies returned metrics data in the lookback window (analytics may be empty or lagging)."
fi

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Error split analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
