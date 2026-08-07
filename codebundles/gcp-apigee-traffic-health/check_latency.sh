#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Latency Performance
#
# Queries proxyv2/percentile latency metrics (p50/p90/p99) and flags proxies
# whose p95/p99 latency exceeds LATENCY_MS_THRESHOLD, indicating slow APIs.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#   LATENCY_MS_THRESHOLD      - p95 latency threshold in ms (default 500)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#
# OPTIONAL ENV VARS:
#   MOCK_DATA_FILE            - Path to mock latency data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   latency_issues.json      - JSON array of issues
#   latency_report.json      - Per-proxy latency values
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LATENCY_MS_THRESHOLD:=500}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="latency_issues.json"
REPORT_FILE="latency_report.json"
issues_json='[]'

window_seconds=$(( METRIC_WINDOW_MIN * 60 ))
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - window_seconds ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing Apigee latency for project: $GCP_PROJECT_ID (p95 threshold: ${LATENCY_MS_THRESHOLD}ms, window: ${METRIC_WINDOW_MIN}m)"

# ---------------------------------------------------------------------------
# Mock path (deterministic tests)
# Expected format: array of {"proxy","p50_ms","p90_ms","p95_ms","p99_ms"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "$MOCK_DATA_FILE" ]; then
    echo "Using mock latency data from $MOCK_DATA_FILE"
    report_json='[]'
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        proxy=$(echo "$row" | jq -r '.proxy')
        p50=$(echo "$row" | jq -r '.p50_ms // 0')
        p90=$(echo "$row" | jq -r '.p90_ms // 0')
        p95=$(echo "$row" | jq -r '.p95_ms // 0')
        p99=$(echo "$row" | jq -r '.p99_ms // 0')
        echo "  proxy '$proxy': p50=${p50}ms p90=${p90}ms p95=${p95}ms p99=${p99}ms"
        report_json=$(echo "$report_json" | jq \
            --arg proxy "$proxy" --arg p50 "$p50" --arg p95 "$p95" --arg p99 "$p99" \
            '. += [{"proxy":$proxy,"p50_ms":($p50|tonumber),"p95_ms":($p95|tonumber),"p99_ms":($p99|tonumber)}]')
        exceeded=$(awk -v p="$p95" -v p9="$p99" -v thr="$LATENCY_MS_THRESHOLD" 'BEGIN { print (p > thr || p9 > thr) ? "1" : "0" }')
        if [ "$exceeded" = "1" ]; then
            issue=$(jq -n \
                --arg title "Apigee proxy \`$proxy\` has high latency" \
                --arg details "Apigee proxy '$proxy' in project '$GCP_PROJECT_ID' has a p95 latency of ${p95}ms (p99 ${p99}ms) in the last ${METRIC_WINDOW_MIN}m, exceeding the threshold of ${LATENCY_MS_THRESHOLD}ms." \
                --arg severity "3" \
                --arg expected "Apigee proxy p95/p99 latency should remain below ${LATENCY_MS_THRESHOLD}ms" \
                --arg actual "Apigee proxy '$proxy' has a p95 latency of ${p95}ms" \
                --arg next_steps "Investigate the slow API. Check backend/target performance, quota and rate-limit policies, and whether a recent proxy revision introduced latency. Review latency percentiles in Cloud Monitoring." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(jq -c '.[]' "$MOCK_DATA_FILE")
    echo "$report_json" > "$REPORT_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    echo "Latency analysis complete (mock). Found $(jq length "$ISSUES_FILE") issue(s)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Live path: Cloud Monitoring
# ---------------------------------------------------------------------------
access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "4" \
        --arg expected "Cloud Monitoring metrics should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$REPORT_FILE"
    exit 0
fi

query_metric_p95_ms() {
    local metric_type="$1"
    local extra_filter="$2"
    local filter="metric.type=\"$metric_type\""
    if [ -n "$extra_filter" ]; then
        filter="$filter AND $extra_filter"
    fi
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_PERCENTILE_95&aggregation.crossSeriesReducer=REDUCE_PERCENTILE_95&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    # Value is in seconds; convert to milliseconds.
    echo "$resp" | jq '[.timeSeries[].points[].value.doubleValue | tonumber] | max // 0 | . * 1000' 2>/dev/null || echo "0"
}

if [ -f "$APIGEE_SCOPE_FILE" ]; then
    proxies=$(jq -r '.proxies[]' "$APIGEE_SCOPE_FILE" 2>/dev/null || true)
else
    proxies=""
fi
if [ -z "$proxies" ]; then
    echo "No proxies to evaluate (scope empty or not found)."
    echo "[]" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

report_json='[]'
while IFS= read -r proxy; do
    [ -z "$proxy" ] && continue
    filter="metric.label.proxy=\"$proxy\""
    p95_ms=$(query_metric_p95_ms "apigee.googleapis.com/proxyv2/latencies_percentile" "$filter")
    p95_ms=$(echo "$p95_ms" | awk '{printf "%.0f", $1}')
    echo "  proxy '$proxy': p95 latency ${p95_ms}ms"
    report_json=$(echo "$report_json" | jq \
        --arg proxy "$proxy" --arg p95 "$p95_ms" \
        '. += [{"proxy":$proxy,"p95_ms":($p95|tonumber)}]')
    if [ "$p95_ms" -gt "$LATENCY_MS_THRESHOLD" ]; then
        issue=$(jq -n \
            --arg title "Apigee proxy \`$proxy\` has high latency" \
            --arg details "Apigee proxy '$proxy' in project '$GCP_PROJECT_ID' has a p95 latency of ${p95_ms}ms in the last ${METRIC_WINDOW_MIN}m, exceeding the threshold of ${LATENCY_MS_THRESHOLD}ms." \
            --arg severity "3" \
            --arg expected "Apigee proxy p95 latency should remain below ${LATENCY_MS_THRESHOLD}ms" \
            --arg actual "Apigee proxy '$proxy' has a p95 latency of ${p95_ms}ms" \
            --arg next_steps "Investigate the slow API. Check backend/target performance, quota and rate-limit policies, and whether a recent proxy revision introduced latency." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done <<< "$proxies"

echo "$report_json" > "$REPORT_FILE"
echo "$issues_json" > "$ISSUES_FILE"
echo "Latency analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
