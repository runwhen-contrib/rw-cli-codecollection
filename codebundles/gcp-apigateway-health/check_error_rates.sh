#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Analyze GCP API Gateway Error Rates
#
# Queries Cloud Monitoring for gateway request error rates over the lookback
# window, flagging 5xx rate above ERROR_RATE_THRESHOLD (backend failing, hand
# off to the Cloud Run bundle, sev 3) and a separate tighter 401/403 rate above
# AUTH_ERROR_RATE_THRESHOLD (JWT issuer / jwks_uri misconfiguration or API key
# enforcement rejecting callers, sev 3).
#
# Metric types are resolved at runtime (see apigateway_common.sh) so a wrong
# metric type does not silently fail. METRIC_TYPE_OVERRIDE can force a type.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ERROR_RATE_THRESHOLD (default 0.01)
#   AUTH_ERROR_RATE_THRESHOLD (default 0.005)
#   METRIC_LOOKBACK_PERIOD (default 3600s)
#
# OUTPUTS:
#   error_rate_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ERROR_RATE_THRESHOLD:=0.01}"
: "${AUTH_ERROR_RATE_THRESHOLD:=0.005}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
. ./apigateway_common.sh

ISSUES_FILE="error_rate_issues.json"
issues='[]'
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing gateway error rates for project: $GCP_PROJECT_ID (5xx threshold: $ERROR_RATE_THRESHOLD, 401/403 threshold: $AUTH_ERROR_RATE_THRESHOLD, lookback: ${METRIC_LOOKBACK_PERIOD})"

access_token=$(apigw_get_access_token)
if [ -z "$access_token" ]; then
    issues=$(echo "$issues" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "3" \
        --arg expected "Cloud Monitoring metrics should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    apigw_write_issues "$ISSUES_FILE" "$issues"
    exit 0
fi

count_metric=$(apigw_resolve_count_metric)

# Helper: query count metric and return total
query_count() {
    local filter="$1"
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
}

total_filter="metric.type=\"$count_metric\""
fivxx_filter="metric.type=\"$count_metric\" AND metric.label.response_code_class=\"5xx\""

total=$(query_count "$total_filter")
fivxx=$(query_count "$fivxx_filter")

total=$(echo "$total" | awk '{printf "%.0f", $1}')
fivxx=$(echo "$fivxx" | awk '{printf "%.0f", $1}')

if [ "$total" = "0" ]; then
    echo "  No request data in lookback window (metric $count_metric)."
else
    ratio=$(awk -v e="$fivxx" -v t="$total" 'BEGIN { printf "%.4f", e/t }')
    echo "  Total requests: $total, 5xx: $fivxx, 5xx ratio: $ratio"
    if [ "$(awk -v r="$ratio" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
        issue=$(jq -n \
            --arg title "API Gateway has a high 5xx error rate" \
            --arg details "API Gateway in project '$GCP_PROJECT_ID' returned $fivxx 5xx responses out of $total requests in the last ${METRIC_LOOKBACK_PERIOD} (5xx ratio $ratio, threshold $ERROR_RATE_THRESHOLD). Elevated 5xx usually indicates the backend is failing." \
            --arg severity "3" \
            --arg expected "Gateway 5xx error rate should remain below $ERROR_RATE_THRESHOLD" \
            --arg actual "Gateway 5xx error ratio is $ratio" \
            --arg next_steps "Hand off to the gcp-cloudrun-service-health bundle to diagnose backend failures. Review backend logs and error rates in Cloud Monitoring for the backing Cloud Run services." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
    fi
fi

# 401/403 rate -- specific codes require the serviceruntime api/request_count metric.
auth_metric="serviceruntime.googleapis.com/api/request_count"
auth_total_filter="metric.type=\"$auth_metric\""
auth_errors_filter="metric.type=\"$auth_metric\" AND (metric.label.response_code=\"401\" OR metric.label.response_code=\"403\")"

auth_total=$(query_count "$auth_total_filter")
auth_errors=$(query_count "$auth_errors_filter")

auth_total=$(echo "$auth_total" | awk '{printf "%.0f", $1}')
auth_errors=$(echo "$auth_errors" | awk '{printf "%.0f", $1}')

if [ "$auth_total" != "0" ]; then
    auth_ratio=$(awk -v e="$auth_errors" -v t="$auth_total" 'BEGIN { printf "%.4f", e/t }')
    echo "  Auth errors (401/403): $auth_errors / $auth_total, ratio: $auth_ratio"
    if [ "$(awk -v r="$auth_ratio" -v thr="$AUTH_ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
        issue=$(jq -n \
            --arg title "API Gateway has a high 401/403 rejection rate" \
            --arg details "API Gateway in project '$GCP_PROJECT_ID' rejected $auth_errors requests with 401/403 out of $auth_total in the last ${METRIC_LOOKBACK_PERIOD} (ratio $auth_ratio, threshold $AUTH_ERROR_RATE_THRESHOLD). This typically indicates a JWT issuer/jwks_uri misconfiguration or API key enforcement rejecting callers." \
            --arg severity "3" \
            --arg expected "Gateway 401/403 rejection rate should remain below $AUTH_ERROR_RATE_THRESHOLD" \
            --arg actual "Gateway 401/403 rejection ratio is $auth_ratio" \
            --arg next_steps "Verify the security definitions in the OpenAPI spec (x-google-issuer, jwks_uri, api keys). Confirm the JWT issuer matches the expected audience/issuer and that API keys are valid. Check gateway logs in Cloud Logging for rejected request reasons." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
    fi
elif [ -n "${METRIC_TYPE_OVERRIDE:-}" ]; then
    echo "  No serviceruntime auth metric data; skipping auth rejection check."
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Error rate analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
