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
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="latency_split_issues.json"
apigee_init_issues "$ISSUES_FILE"
apigee_reset_api_errors
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
    issues_json=$(apigee_append_api_error_issue "$issues_json" "the latency and overhead analysis" "$ORG")
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi
echo "  Environments in scope: $(echo "$environments" | jq -r 'join(", ")')"

lat_list=""; lat_n=0
ovh_list=""; ovh_n=0

for env in $(echo "$environments" | jq -r '.[]'); do
    echo "  Querying latency stats for environment '$env'..."
    resp=$(apigee_stats "$ORG" "$env" "apiproxy" "$pair_query" "$t_start" "$t_end")
    dims=$(printf '%s' "$resp" | apigee_stats_dimensions)

    # Process substitution: a pipe would run this loop in a subshell and discard
    # every list appended below, once per environment.
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
            lat_list="${lat_list}  - ${proxy} (env ${env}): ${LATENCY_PERCENTILE_FN} total ${total_ms}ms (target portion ${target_ms}ms)"$'\n'
            lat_n=$((lat_n + 1))
        fi

        # A proxy with no target (all responses served from the proxy itself)
        # reports target_response_time 0. Calling the whole response time
        # "Apigee overhead" there would flag every such proxy on every run.
        if [ "$(awk -v v="$target_ms" 'BEGIN { print (v > 0) ? 1 : 0 }')" != "1" ]; then
            echo "    Proxy '$proxy': no target_response_time; skipping overhead comparison."
            continue
        fi

        if [ "$(awk -v v="$overhead" -v thr="$OVERHEAD_MS_THRESHOLD" 'BEGIN { print (v > thr) ? 1 : 0 }')" = "1" ]; then
            ovh_list="${ovh_list}  - ${proxy} (env ${env}): ${overhead}ms overhead (${LATENCY_PERCENTILE_FN} total ${total_ms}ms minus target ${target_ms}ms)"$'\n'
            ovh_n=$((ovh_n + 1))
        fi
    done < <(printf '%s' "$dims" | jq -c '.[]')
done

# The percentile function is config, so it stays out of the title too: changing
# LATENCY_PERCENTILE_FN would otherwise retitle the issue and orphan the old one.
if [ "$lat_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have high response latency in org \`$ORG\`" 3 \
        "Percentile total_response_time should remain below LATENCY_MS_THRESHOLD" \
        "$lat_n proxy/environment pair(s) exceed the latency threshold" \
        "Investigate latency for the proxies listed. Cross-reference the processing-overhead issue to decide whether the bottleneck is Apigee itself or the backend." \
        "Measured as ${LATENCY_PERCENTILE_FN}(total_response_time), threshold ${LATENCY_MS_THRESHOLD}ms over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$lat_n over threshold:"$'\n'"$lat_list")" '. += [$i]')
fi

if [ "$ovh_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies have high Apigee processing overhead in org \`$ORG\`" 3 \
        "Apigee processing overhead should remain below OVERHEAD_MS_THRESHOLD" \
        "$ovh_n proxy/environment pair(s) exceed the overhead threshold" \
        "The proxy LOGIC is the bottleneck, not the backend. Investigate the policy chain for the proxies listed: callouts, KVM lookups, JSON/XML transforms, crypto." \
        "Overhead is total minus target response time, threshold ${OVERHEAD_MS_THRESHOLD}ms over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$ovh_n over threshold:"$'\n'"$ovh_list")" '. += [$i]')
fi

issues_json=$(apigee_append_api_error_issue "$issues_json" "the latency and overhead analysis" "$ORG")
echo "$issues_json" > "$ISSUES_FILE"
echo "Latency split analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
