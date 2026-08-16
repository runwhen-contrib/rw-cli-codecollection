#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Cloud SQL Instance Storage Growth in a GCP Project
#
# Detects instances at risk of running out of disk by comparing used storage
# (from Cloud Monitoring) to configured capacity (from instance settings) and
# flagging high-fill instances, especially those without automatic storage
# increase enabled.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID              - GCP project ID hosting the Cloud SQL instances
#   RESOURCES                   - Optional comma-separated instance names (default All)
#   STORAGE_FILL_THRESHOLD_PERCENT - Fill percent above which an instance without
#                                    autoresize is flagged (default 80)
#
# OUTPUTS:
#   storage_issues.json  - JSON array of issues
#   storage_report.json  - JSON array of per-instance storage data
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${STORAGE_FILL_THRESHOLD_PERCENT:=80}"
: "${STORAGE_CRITICAL_THRESHOLD_PERCENT:=92}"

ISSUES_FILE="storage_issues.json"
REPORT_FILE="storage_report.json"
CONFIG_FILE="sql_config.json"
issues_json='[]'

echo "Checking Cloud SQL storage growth for project: $GCP_PROJECT_ID (fill threshold: ${STORAGE_FILL_THRESHOLD_PERCENT}%)"

if [ ! -s "sql_config.json" ]; then
    echo "No sql_config.json found; running discovery first."
    ./discover_sql_instances.sh
fi

# Fail loud: if discovery could not list the Cloud SQL instances (auth/permission
# failure, API disabled, etc.), surface those discovery issues here instead of
# silently proceeding with an empty instance set and reporting "0 issues / healthy".
if [ -s "sql_instances_issues.json" ] && [ "$(jq 'length' sql_instances_issues.json 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "Cloud SQL discovery reported failure(s); surfacing them instead of scoring as healthy."
    cp sql_instances_issues.json "$ISSUES_FILE"
    echo "[]" > "$REPORT_FILE"
    exit 0
fi

access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "2" \
        --arg expected "Cloud Monitoring metrics should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$REPORT_FILE"
    exit 0
fi

end_time=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "-1 hour" "+%Y-%m-%dT%H:%M:%SZ")

query_bytes_used() {
    local database_id="$1"
    local filter="metric.type=\"cloudsql.googleapis.com/database/disk/bytes_used\" AND resource.labels.database_id=\"$database_id\""
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=300s&aggregation.perSeriesAligner=ALIGN_LAST&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.doubleValue // .int64Value // 0) | tonumber] | last // 0' 2>/dev/null || echo "0"
}

report='[]'
while IFS= read -r line; do
    inst_name=$(echo "$line" | jq -r '.name')
    db_id=$(echo "$line" | jq -r '.database_id')
    disk_size_gb=$(echo "$line" | jq -r '.disk_size_gb')
    autoresize=$(echo "$line" | jq -r '.disk_autoresize')

    bytes_used=$(query_bytes_used "$db_id")
    used_gb=$(echo "$bytes_used" | awk '{printf "%.2f", $1/1073741824}')
    fill=$(awk -v u="$used_gb" -v c="$disk_size_gb" 'BEGIN{ if (c+0>0) printf "%.2f", u/c*100; else print 0 }')

    report=$(echo "$report" | jq \
        --arg name "$inst_name" \
        --arg used "$used_gb" \
        --arg cap "$disk_size_gb" \
        --arg fill "$fill" \
        --arg ar "$autoresize" \
        '. + [{"name":$name,"used_gb":($used|tonumber),"capacity_gb":($cap|tonumber),"fill_percent":($fill|tonumber),"disk_autoresize":($ar|test("true"))}]')

    echo "  Instance '$inst_name': used=${used_gb}GB capacity=${disk_size_gb}GB fill=${fill}% autoresize=${autoresize}"

    # Severity 4: critically full regardless of autoresize.
    if [ "$(awk -v f="$fill" -v c="$STORAGE_CRITICAL_THRESHOLD_PERCENT" 'BEGIN{print (f>=c)?1:0}')" = "1" ]; then
        issue=$(jq -n \
            --arg title "Cloud SQL instance \`$inst_name\` is critically low on storage" \
            --arg details "Instance '$inst_name' in project '$GCP_PROJECT_ID' is ${fill}% full (${used_gb}GB of ${disk_size_gb}GB used). $([ "$autoresize" = "true" ] && echo "Automatic storage increase is enabled." || echo "Automatic storage increase is disabled.")" \
            --arg severity "4" \
            --arg expected "Cloud SQL storage fill should remain below ${STORAGE_CRITICAL_THRESHOLD_PERCENT}%" \
            --arg actual "Instance '$inst_name' is ${fill}% full" \
            --arg next_steps "Increase the instance's storage capacity or enable automatic storage increase immediately to avoid running out of disk." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
        continue
    fi

    # Severity 3: high fill AND no automatic storage increase.
    if [ "$(awk -v f="$fill" -v t="$STORAGE_FILL_THRESHOLD_PERCENT" 'BEGIN{print (f>=t)?1:0}')" = "1" ] && [ "$autoresize" != "true" ]; then
        issue=$(jq -n \
            --arg title "Cloud SQL instance \`$inst_name\` is at risk of running out of disk" \
            --arg details "Instance '$inst_name' in project '$GCP_PROJECT_ID' is ${fill}% full (${used_gb}GB of ${disk_size_gb}GB used) and does not have automatic storage increase enabled, so it cannot grow automatically." \
            --arg severity "3" \
            --arg expected "Cloud SQL storage should have headroom and/or automatic storage increase enabled" \
            --arg actual "Instance '$inst_name' is ${fill}% full with automatic storage increase disabled" \
            --arg next_steps "Enable automatic storage increase or increase the disk size to prevent running out of disk. See https://cloud.google.com/sql/docs/mysql/instance-settings." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done < <(jq -c '.[]' "$CONFIG_FILE")

echo "$report" > "$REPORT_FILE"
if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Storage growth check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
