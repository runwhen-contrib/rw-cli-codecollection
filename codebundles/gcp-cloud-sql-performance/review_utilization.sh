#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Review Cloud SQL Instance Utilization in a GCP Project
#
# Evaluates CPU, memory, and disk utilization for each Cloud SQL instance via
# Cloud Monitoring metrics over the look-back window, flagging instances whose
# utilization is consistently above the configured threshold.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID         - GCP project ID hosting the Cloud SQL instances
#   RESOURCES              - Optional comma-separated instance names (default All)
#   CPU_THRESHOLD_PERCENT  - CPU utilization percent above which an instance is
#                            flagged (default 80)
#   UTILIZATION_HOURS      - Look-back window in hours (default 6)
#
# OUTPUTS:
#   utilization_issues.json - JSON array of issues
#   utilization_report.json - JSON array of per-instance utilization data
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${CPU_THRESHOLD_PERCENT:=80}"
: "${UTILIZATION_HOURS:=6}"

ISSUES_FILE="utilization_issues.json"
REPORT_FILE="utilization_report.json"
CONFIG_FILE="sql_config.json"
issues_json='[]'

echo "Reviewing Cloud SQL utilization for project: $GCP_PROJECT_ID (CPU threshold: ${CPU_THRESHOLD_PERCENT}%, lookback: ${UTILIZATION_HOURS}h)"

if [ ! -s "sql_config.json" ]; then
    echo "No sql_config.json found; running discovery first."
    ./discover_sql_instances.sh
fi

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

start_epoch=$(( $(date +%s) - UTILIZATION_HOURS * 3600 ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# query_utilization <database_id> <metric_type>
# Returns average utilization percentage (number 0-100) for the metric, or 0.
query_utilization() {
    local database_id="$1"
    local metric_type="$2"
    local filter="metric.type=\"$metric_type\" AND resource.labels.database_id=\"$database_id\""
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=300s&aggregation.perSeriesAligner=ALIGN_MEAN&aggregation.crossSeriesReducer=REDUCE_MEAN&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.doubleValue // .int64Value // 0) | tonumber] | add // 0' 2>/dev/null | \
        awk -v n=1 '{ if (n==0) print 0; else printf "%.2f", $1 }'
}

report='[]'
while IFS= read -r line; do
    inst_name=$(echo "$line" | jq -r '.name')
    db_id=$(echo "$line" | jq -r '.database_id')

    cpu=$(query_utilization "$db_id" "cloudsql.googleapis.com/database/cpu/utilization")
    mem=$(query_utilization "$db_id" "cloudsql.googleapis.com/database/memory/utilization")
    disk=$(query_utilization "$db_id" "cloudsql.googleapis.com/database/disk/utilization")

    cpu=$(echo "$cpu" | awk '{printf "%.2f", $1*100}')
    mem=$(echo "$mem" | awk '{printf "%.2f", $1*100}')
    disk=$(echo "$disk" | awk '{printf "%.2f", $1*100}')

    report=$(echo "$report" | jq \
        --arg name "$inst_name" \
        --arg cpu "$cpu" \
        --arg mem "$mem" \
        --arg disk "$disk" \
        '. + [{"name":$name,"cpu_percent":($cpu|tonumber),"memory_percent":($mem|tonumber),"disk_percent":($disk|tonumber)}]')

    echo "  Instance '$inst_name': cpu=${cpu}% mem=${mem}% disk=${disk}%"

    if [ "$(awk -v c="$cpu" -v t="$CPU_THRESHOLD_PERCENT" 'BEGIN{print (c>t)?1:0}')" = "1" ]; then
        issue=$(jq -n \
            --arg title "Cloud SQL instance \`$inst_name\` is over-utilized on CPU" \
            --arg details "Instance '$inst_name' in project '$GCP_PROJECT_ID' sustained ${cpu}% CPU utilization over the last ${UTILIZATION_HOURS}h, above the ${CPU_THRESHOLD_PERCENT}% threshold." \
            --arg severity "3" \
            --arg expected "Cloud SQL CPU utilization should remain below ${CPU_THRESHOLD_PERCENT}%" \
            --arg actual "Instance '$inst_name' CPU utilization is ${cpu}%" \
            --arg next_steps "Right-size the instance (increase CPU/memory tier) or review query load. See https://cloud.google.com/sql/docs/mysql/instance-settings for tier options." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done < <(jq -c '.[]' "$CONFIG_FILE")

echo "$report" > "$REPORT_FILE"
if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Utilization review complete. Found $(jq length "$ISSUES_FILE") issue(s)."
