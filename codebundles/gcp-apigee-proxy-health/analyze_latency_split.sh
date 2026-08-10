#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# analyze_latency_split.sh
# Queries percentile total_response_time and target_response_time from
# Analytics. Flags proxies whose p95 total_response_time exceeds
# LATENCY_MS_THRESHOLD, and flags when the gap between total_response_time and
# target_response_time exceeds OVERHEAD_MS_THRESHOLD -- that gap is Apigee's own
# processing overhead, isolating a proxy-logic bottleneck from a slow backend.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          - GCP project owning the Apigee org
#   APIGEE_ORG              - optional; Apigee org (resolved if empty)
#   LATENCY_MS_THRESHOLD    - max p95 total_response_time in ms (default 5000)
#   OVERHEAD_MS_THRESHOLD   - max Apigee processing overhead in ms (default 500)
#   ANALYTICS_WINDOW_MIN    - lookback window in minutes (default 60)
#   LATENCY_PERCENTILE_FN   - percentile function name (default p95)
#
# NOTE: the aggregation functions the stats endpoint accepts are org- and
# schema-dependent. If LATENCY_PERCENTILE_FN is not supported the API returns an
# empty series, which this script reports as "no latency data" rather than as
# healthy. Confirm supported functions against
# /organizations/{org}/environments/{env}/analytics/admin/schemav2.
#
# OUTPUTS:
#   latency_split_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
LATENCY_MS_THRESHOLD="${LATENCY_MS_THRESHOLD:-5000}"
OVERHEAD_MS_THRESHOLD="${OVERHEAD_MS_THRESHOLD:-500}"
ANALYTICS_WINDOW_MIN="${ANALYTICS_WINDOW_MIN:-60}"
LATENCY_PERCENTILE_FN="${LATENCY_PERCENTILE_FN:-p95}"
PROXIES="${PROXIES:-All}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="latency_split_issues.json"
apigee_init_issues "$ISSUES_FILE"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping latency split analysis (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing latency & processing overhead for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, ${LATENCY_PERCENTILE_FN}>${LATENCY_MS_THRESHOLD}ms, overhead>${OVERHEAD_MS_THRESHOLD}ms)"

pair_query="${LATENCY_PERCENTILE_FN}(total_response_time),${LATENCY_PERCENTILE_FN}(target_response_time)"
proxy_filter="$(apigee_expand_csv "$PROXIES")"

environments=$(apigee_list_environments "$ORG")
env_count=$(echo "$environments" | jq length)
if [ "$env_count" -eq 0 ]; then
    echo "No environments resolved for org '$ORG'; cannot analyze Analytics."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi
echo "  Environments in scope: $(echo "$environments" | jq -r 'join(", ")')"

for env in $(echo "$environments" | jq -r '.[]'); do
    echo "  Querying latency stats for environment '$env'..."
    resp=$(apigee_stats "$ORG" "$env" "apiproxy" "$pair_query" "$t_start" "$t_end")
    dims=$(printf '%s' "$resp" | apigee_stats_dimensions)

    # Process substitution: a pipe would run this loop in a subshell and discard
    # every issue appended below, once per environment.
    while read -r dim; do
        proxy=$(apigee_dimension_part "$dim" 0)
        [ -z "$proxy" ] && continue
        if [ "$proxy_filter" != "All" ]; then
            echo "$proxy_filter" | tr ',' '\n' | grep -qxF "$proxy" || continue
        fi

        # Percentiles across buckets are aggregated with max, not sum: adding
        # per-bucket p95s would invent latency that never happened.
        total_ms=$(apigee_metric "$dim" "total_response_time" max)
        target_ms=$(apigee_metric "$dim" "target_response_time" max)

        if [ "$(awk -v v="$total_ms" 'BEGIN { print (v > 0) ? 1 : 0 }')" != "1" ]; then
            echo "    Proxy '$proxy': no latency data in window."
            continue
        fi

        overhead=$(awk -v t="$total_ms" -v g="$target_ms" 'BEGIN { printf "%.0f", t - g }')
        echo "    Proxy '$proxy': ${LATENCY_PERCENTILE_FN} total=${total_ms}ms target=${target_ms}ms overhead=${overhead}ms"

        if [ "$(awk -v v="$total_ms" -v thr="$LATENCY_MS_THRESHOLD" 'BEGIN { print (v > thr) ? 1 : 0 }')" = "1" ]; then
            issue=$(jq -n \
                --arg title "High ${LATENCY_PERCENTILE_FN} latency for proxy \`$proxy\` (env \`$env\`)" \
                --arg details "Proxy '$proxy' ${LATENCY_PERCENTILE_FN} total_response_time is ${total_ms}ms in the last ${ANALYTICS_WINDOW_MIN}m, exceeding LATENCY_MS_THRESHOLD ${LATENCY_MS_THRESHOLD}ms (target portion: ${target_ms}ms)." \
                --arg severity "3" \
                --arg expected "${LATENCY_PERCENTILE_FN} total_response_time should remain below $LATENCY_MS_THRESHOLD ms" \
                --arg actual "Proxy '$proxy' ${LATENCY_PERCENTILE_FN} total_response_time is ${total_ms}ms" \
                --arg next_steps "Investigate latency for '$proxy' in '$env'. Cross-reference the overhead split to decide whether the bottleneck is Apigee processing or the backend." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi

        # A proxy with no target (all responses served from the proxy itself)
        # reports target_response_time 0. Calling the whole response time
        # "Apigee overhead" there would flag every such proxy on every run.
        if [ "$(awk -v v="$target_ms" 'BEGIN { print (v > 0) ? 1 : 0 }')" != "1" ]; then
            echo "    Proxy '$proxy': no target_response_time; skipping overhead comparison."
            continue
        fi

        if [ "$(awk -v v="$overhead" -v thr="$OVERHEAD_MS_THRESHOLD" 'BEGIN { print (v > thr) ? 1 : 0 }')" = "1" ]; then
            issue=$(jq -n \
                --arg title "High Apigee processing overhead for proxy \`$proxy\` (env \`$env\`)" \
                --arg details "Proxy '$proxy' has ${overhead}ms of Apigee processing overhead (${LATENCY_PERCENTILE_FN} total ${total_ms}ms minus target ${target_ms}ms), exceeding OVERHEAD_MS_THRESHOLD ${OVERHEAD_MS_THRESHOLD}ms. The proxy LOGIC is the bottleneck, not the backend." \
                --arg severity "3" \
                --arg expected "Apigee processing overhead should remain below $OVERHEAD_MS_THRESHOLD ms" \
                --arg actual "Proxy '$proxy' processing overhead is ${overhead}ms" \
                --arg next_steps "Investigate the proxy policy chain for '$proxy' in '$env' (callouts, KVM lookups, JSON/XML transforms, crypto). The backend is fast; the proxy logic is adding latency." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(printf '%s' "$dims" | jq -c '.[]')
done

echo "$issues_json" > "$ISSUES_FILE"
echo "Latency split analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
