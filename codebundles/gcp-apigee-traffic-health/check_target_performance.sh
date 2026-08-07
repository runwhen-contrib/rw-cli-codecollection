#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Target and Backend Performance
#
# Queries target/upstream request, response, and latency metrics to detect slow
# or failing backend target servers, flagging targets with elevated latency or
# errors.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#   ERROR_RATE_THRESHOLD      - Max target error rate in percent (default 5)
#   LATENCY_MS_THRESHOLD      - Target p95 latency threshold in ms (default 500)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#
# OPTIONAL ENV VARS:
#   MOCK_DATA_FILE            - Path to mock target data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   target_performance_issues.json - JSON array of issues
#   target_report.json             - Per-target performance summary
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ERROR_RATE_THRESHOLD:=5}"
: "${LATENCY_MS_THRESHOLD:=500}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="target_performance_issues.json"
REPORT_FILE="target_report.json"
issues_json='[]'

window_seconds=$(( METRIC_WINDOW_MIN * 60 ))
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - window_seconds ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing Apigee target/backend performance for project: $GCP_PROJECT_ID (window: ${METRIC_WINDOW_MIN}m)"

# ---------------------------------------------------------------------------
# Mock path (deterministic tests)
# Expected format: array of {"target","environment","error_rate_percent","p95_latency_ms"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "$MOCK_DATA_FILE" ]; then
    echo "Using mock target data from $MOCK_DATA_FILE"
    report_json='[]'
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        target=$(echo "$row" | jq -r '.target')
        environment=$(echo "$row" | jq -r '.environment // ""')
        err_rate=$(echo "$row" | jq -r '.error_rate_percent // 0')
        p95=$(echo "$row" | jq -r '.p95_latency_ms // 0')
        echo "  target '$target' (env '$environment'): error_rate=${err_rate}% p95=${p95}ms"
        report_json=$(echo "$report_json" | jq \
            --arg target "$target" --arg environment "$environment" --arg err "$err_rate" --arg p95 "$p95" \
            '. += [{"target":$target,"environment":$environment,"error_rate_percent":($err|tonumber),"p95_latency_ms":($p95|tonumber)}]')
        bad_err=$(awk -v e="$err_rate" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (e > thr) ? "1" : "0" }')
        bad_lat=$(awk -v p="$p95" -v thr="$LATENCY_MS_THRESHOLD" 'BEGIN { print (p > thr) ? "1" : "0" }')
        if [ "$bad_err" = "1" ] || [ "$bad_lat" = "1" ]; then
            reason=""
            if [ "$bad_err" = "1" ]; then reason="error rate ${err_rate}% exceeds ${ERROR_RATE_THRESHOLD}%"; fi
            if [ "$bad_lat" = "1" ]; then
                if [ -n "$reason" ]; then reason="$reason; "; fi
                reason="${reason}p95 latency ${p95}ms exceeds ${LATENCY_MS_THRESHOLD}ms"
            fi
            issue=$(jq -n \
                --arg title "Apigee target server \`$target\` is degraded" \
                --arg details "Target server '$target' (environment '$environment') in project '$GCP_PROJECT_ID' is degraded: $reason over the last ${METRIC_WINDOW_MIN}m." \
                --arg severity "3" \
                --arg expected "Apigee target servers should have low error rates and acceptable latency" \
                --arg actual "Target server '$target' is degraded ($reason)" \
                --arg next_steps "Investigate the upstream backend/target server. Check target health, capacity, and configuration; confirm the backend service is responding and not timing out." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(jq -c '.[]' "$MOCK_DATA_FILE")
    echo "$report_json" > "$REPORT_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    echo "Target performance analysis complete (mock). Found $(jq length "$ISSUES_FILE") issue(s)."
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

query_metric_count() {
    local metric_type="$1"
    local extra_filter="$2"
    local filter="metric.type=\"$metric_type\""
    if [ -n "$extra_filter" ]; then
        filter="$filter AND $extra_filter"
    fi
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
}

if [ -f "$APIGEE_SCOPE_FILE" ]; then
    targets=$(jq -c '.target_servers[]' "$APIGEE_SCOPE_FILE" 2>/dev/null || true)
else
    targets=""
fi
if [ -z "$targets" ]; then
    echo "No target servers to evaluate (scope empty or not found)."
    echo "[]" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

report_json='[]'
while IFS= read -r target_obj; do
    [ -z "$target_obj" ] && continue
    target=$(echo "$target_obj" | jq -r '.name')
    environment=$(echo "$target_obj" | jq -r '.environment // ""')
    filter="metric.label.target_server=\"$target\""
    [ -n "$environment" ] && filter="$filter AND metric.label.environment=\"$environment\""
    total=$(query_metric_count "apigee.googleapis.com/targetv2/request_count" "$filter")
    errors=$(query_metric_count "apigee.googleapis.com/targetv2/request_count" "$filter AND metric.label.response_code_class=\"5xx\"")
    total=$(echo "$total" | awk '{printf "%.0f", $1}')
    errors=$(echo "$errors" | awk '{printf "%.0f", $1}')
    # Latency not easily available in target counters; use error rate primarily.
    err_rate=0
    if [ "$total" -gt 0 ]; then
        err_rate=$(awk -v e="$errors" -v t="$total" 'BEGIN { printf "%.2f", (e*100)/t }')
    fi
    echo "  target '$target' (env '$environment'): errors=$errors total=$total error_rate=${err_rate}%"
    report_json=$(echo "$report_json" | jq \
        --arg target "$target" --arg environment "$environment" --arg err "$err_rate" \
        '. += [{"target":$target,"environment":$environment,"error_rate_percent":($err|tonumber),"p95_latency_ms":0}]')
    bad_err=$(awk -v e="$err_rate" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (e > thr) ? "1" : "0" }')
    if [ "$bad_err" = "1" ]; then
        issue=$(jq -n \
            --arg title "Apigee target server \`$target\` has a high error rate" \
            --arg details "Target server '$target' (environment '$environment') in project '$GCP_PROJECT_ID' has a ${err_rate}% error rate over the last ${METRIC_WINDOW_MIN}m, exceeding the threshold of ${ERROR_RATE_THRESHOLD}%." \
            --arg severity "3" \
            --arg expected "Apigee target servers should have error rates below ${ERROR_RATE_THRESHOLD}%" \
            --arg actual "Target server '$target' has a ${err_rate}% error rate" \
            --arg next_steps "Investigate the upstream backend/target server. Check target health, capacity, and configuration; confirm the backend service is responding and not returning 5xx errors." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done <<< "$targets"

echo "$report_json" > "$REPORT_FILE"
echo "$issues_json" > "$ISSUES_FILE"
echo "Target performance analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
