#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Runtime Environment Status
#
# Verifies Apigee runtime availability per environment using the
# apigee.googleapis.com/environment/active managed metric via Cloud Monitoring.
# Flags environments that are inactive or otherwise unavailable.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG            - Apigee organization name
#   GCP_PROJECT_ID        - GCP project hosting the Apigee runtime
#   METRIC_LOOKBACK_PERIOD- Cloud Monitoring lookback period (default 3600s)
#
# OUTPUTS:
#   runtime_issues.json   - JSON array of runtime/status issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"

ISSUES_FILE="runtime_issues.json"
issues_json='[]'
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Checking Apigee runtime status for org: $APIGEE_ORG in project: $GCP_PROJECT_ID"

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "4" \
        --arg expected "Apigee runtime metrics should be retrievable" \
        --arg actual "Could not obtain an access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer on project $GCP_PROJECT_ID." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

api_get() {
    curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/json" "$@"
}

if [ ! -f "proxy_discovery.json" ]; then
    ./discover_proxies.sh >/dev/null 2>&1 || true
fi

if [ -f "proxy_discovery.json" ]; then
    env_names=$(jq -r '.environments[]?.name // empty' proxy_discovery.json)
else
    envs_json=$(api_get "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments" 2>/dev/null || echo "{}")
    env_names=$(echo "$envs_json" | jq -r '.environments[]? // empty')
fi

if [ -z "$env_names" ]; then
    echo "No environments found for org $APIGEE_ORG."
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

while IFS= read -r env; do
    [ -z "$env" ] && continue
    encoded=$(jq -rn --arg v "metric.type=\"apigee.googleapis.com/environment/active\" AND resource.labels.environment_name=\"$env\"" '$v|@uri')
    url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_MEAN&aggregation.crossSeriesReducer=REDUCE_MAX&view=FULL"
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")

    if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
        issue=$(jq -n \
            --arg title "Cannot query runtime status for Apigee environment \`$env\`" \
            --arg details "Cloud Monitoring query for metric apigee.googleapis.com/environment/active in environment '$env' returned invalid/unparseable data for org '$APIGEE_ORG'." \
            --arg severity "4" \
            --arg expected "Runtime status metric should be queryable for environment '$env'" \
            --arg actual "Cloud Monitoring query failed for environment '$env'" \
            --arg next_steps "Verify the Monitoring API is enabled and the service account has roles/monitoring.viewer." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
        continue
    fi

    # The environment/active metric is 1 when active, 0 when inactive.
    active=$(echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // .stringValue // 0)] | map(tonumber? // 0) | add // 0' 2>/dev/null || echo "0")
    points=$(echo "$resp" | jq '[.timeSeries[].points[]] | length' 2>/dev/null || echo "0")

    if [ "$points" -eq 0 ]; then
        echo "  Environment '$env': no environment/active data points in lookback window."
        continue
    fi

    if [ "$(echo "$active" | awk '{print ($1 <= 0) ? 1 : 0}')" = "1" ]; then
        issue=$(jq -n \
            --arg title "Apigee environment \`$env\` runtime is inactive" \
            --arg details "Cloud Monitoring shows the apigee.googleapis.com/environment/active metric for environment '$env' in org '$APIGEE_ORG' summing to $active over the last ${METRIC_LOOKBACK_PERIOD}, indicating the runtime is inactive/unavailable." \
            --arg severity "4" \
            --arg expected "Environment '$env' runtime should be active and serving traffic" \
            --arg actual "Environment '$env' has environment/active value $active (inactive)" \
            --arg next_steps "Investigate the Apigee runtime for environment '$env': check instance health, routing, and provisioning status in the Apigee console/API. See https://console.cloud.google.com/monitoring/metrics-explorer for the metric." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    else
        echo "  Environment '$env': runtime active (value $active) - OK."
    fi
done <<< "$env_names"

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Runtime status check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
