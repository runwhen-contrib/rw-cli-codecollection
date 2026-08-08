#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# analyze_latency_split.sh
# Queries avg/percentile total_response_time and target_response_time from
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
PROXIES="${PROXIES:-All}"
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="latency_split_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping latency split analysis."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing latency & processing overhead for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, p95>${LATENCY_MS_THRESHOLD}ms, overhead>${OVERHEAD_MS_THRESHOLD}ms)"

pair_query="p95(total_response_time),p95(target_response_time)"

for env in $(apigee_list_environments "$ORG" | jq -r '.[]'); do
    echo "  Querying latency stats for environment '$env'..."
    resp=$(apigee_stats "$ORG" "$env" "apiproxy" "$pair_query" "$t_start" "$t_end")

    echo "$resp" | jq -c '.environments[0].dimensions // []' | jq -c --arg f "$(apigee_expand_csv "$PROXIES")" '
        .[] |
        if $f == "All" then .
        else select(.name as $n | ($f | split(",")) | index($n))
        end' | while read -r dim; do
            proxy=$(echo "$dim" | jq -r '.name')
            total_ms=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("total_response_time")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')
            target_ms=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("target_response_time")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')

            [ -z "$total_ms" ] && { echo "    Proxy '$proxy': no latency data."; continue; }
            overhead=$(( total_ms - target_ms ))
            echo "    Proxy '$proxy': p95 total=${total_ms}ms target=${target_ms}ms overhead=${overhead}ms"

            if [ "$total_ms" -gt "$LATENCY_MS_THRESHOLD" ]; then
                issue=$(jq -n \
                    --arg title "High p95 latency for proxy \`$proxy\` (env \`$env\`)" \
                    --arg details "Proxy '$proxy' p95 total_response_time is ${total_ms}ms in the last ${ANALYTICS_WINDOW_MIN}m, exceeding LATENCY_MS_THRESHOLD ${LATENCY_MS_THRESHOLD}ms (target portion: ${target_ms}ms)." \
                    --arg severity "3" \
                    --arg expected "p95 total_response_time should remain below $LATENCY_MS_THRESHOLD ms" \
                    --arg actual "Proxy '$proxy' p95 total_response_time is ${total_ms}ms" \
                    --arg next_steps "Investigate latency for '$proxy' in '$env'. Cross-reference the overhead split to decide whether the bottleneck is Apigee processing or the backend." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi

            if [ "$overhead" -gt "$OVERHEAD_MS_THRESHOLD" ]; then
                issue=$(jq -n \
                    --arg title "High Apigee processing overhead for proxy \`$proxy\` (env \`$env\`)" \
                    --arg details "Proxy '$proxy' has ${overhead}ms of Apigee processing overhead (p95 total ${total_ms}ms minus target ${target_ms}ms), exceeding OVERHEAD_MS_THRESHOLD ${OVERHEAD_MS_THRESHOLD}ms. The proxy LOGIC is the bottleneck, not the backend." \
                    --arg severity "3" \
                    --arg expected "Apigee processing overhead should remain below $OVERHEAD_MS_THRESHOLD ms" \
                    --arg actual "Proxy '$proxy' processing overhead is ${overhead}ms" \
                    --arg next_steps "Investigate the proxy policy chain for '$proxy' in '$env' (callouts, KVM lookups, JSON/XML transforms, crypto). The backend is fast; the proxy logic is adding latency." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi
    done
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Latency split analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
