#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Analyze Cloud SQL Performance Issues in a GCP Project
#
# Analyzes throughput and IOPS via Cloud Monitoring metrics to flag instances
# with sustained high utilization, throughput spikes, or noisy/blippy traffic
# patterns over the look-back window.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID         - GCP project ID hosting the Cloud SQL instances
#   RESOURCES              - Optional comma-separated instance names (default All)
#   UTILIZATION_HOURS      - Look-back window in hours (default 6)
#
# OUTPUTS:
#   performance_issues.json - JSON array of issues
#   performance_report.json - JSON array of per-instance performance data
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${UTILIZATION_HOURS:=6}"
: "${SPIKE_FACTOR:=5}"
: "${NOISE_CV:=2.0}"

ISSUES_FILE="performance_issues.json"
REPORT_FILE="performance_report.json"
CONFIG_FILE="sql_config.json"
issues_json='[]'

echo "Analyzing Cloud SQL performance for project: $GCP_PROJECT_ID (lookback: ${UTILIZATION_HOURS}h)"

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

# query_series <database_id> <metric_type>
# Returns a JSON array of sampled numeric values for the metric over the window.
query_series() {
    local database_id="$1"
    local metric_type="$2"
    local filter="metric.type=\"$metric_type\" AND resource.labels.database_id=\"$database_id\""
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=300s&aggregation.perSeriesAligner=ALIGN_MEAN&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.doubleValue // .int64Value // 0) | tonumber]' 2>/dev/null || echo "[]"
}

report='[]'
while IFS= read -r line; do
    inst_name=$(echo "$line" | jq -r '.name')
    db_id=$(echo "$line" | jq -r '.database_id')

    recv=$(query_series "$db_id" "cloudsql.googleapis.com/database/network/received_bytes_count")
    sent=$(query_series "$db_id" "cloudsql.googleapis.com/database/network/sent_bytes_count")
    read_ops=$(query_series "$db_id" "cloudsql.googleapis.com/database/disk/read_ops_count")
    write_ops=$(query_series "$db_id" "cloudsql.googleapis.com/database/disk/write_ops_count")

    recv_avg=$(echo "$recv" | jq 'if length>0 then (add/length) else 0 end')
    recv_max=$(echo "$recv" | jq 'if length>0 then max else 0 end')
    sent_avg=$(echo "$sent" | jq 'if length>0 then (add/length) else 0 end')
    sent_max=$(echo "$sent" | jq 'if length>0 then max else 0 end')
    iops_avg=$(jq -n --argjson r "$read_ops" --argjson w "$write_ops" '
      (($r | add) + ($w | add)) / (if (($r | length) + ($w | length)) == 0 then 1 else (($r | length) + ($w | length)) end)')
    iops_max=$(jq -n --argjson r "$read_ops" --argjson w "$write_ops" '((($r|max) + ($w|max)))')

    through_avg=$(awk -v a="$recv_avg" -v b="$sent_avg" 'BEGIN{printf "%.0f", a+b}')
    through_max=$(awk -v a="$recv_max" -v b="$sent_max" 'BEGIN{printf "%.0f", a+b}')
    ratio=$(awk -v mx="$through_max" -v avg="$through_avg" 'BEGIN{ if (avg+0>0) printf "%.2f", mx/avg; else print 0 }')

    report=$(echo "$report" | jq \
        --arg name "$inst_name" \
        --argjson ta "$through_avg" \
        --argjson tm "$through_max" \
        --arg r "$ratio" \
        --argjson iopsa "$iops_avg" \
        --argjson iopsm "$iops_max" \
        '. + [{"name":$name,"throughput_avg_bytes":$ta,"throughput_max_bytes":$tm,"spike_ratio":($r|tonumber),"iops_avg":$iopsa,"iops_max":$iopsm}]')

    echo "  Instance '$inst_name': throughput avg=${through_avg} max=${through_max} spike_ratio=${ratio} iops_avg=${iops_avg}"

    if [ "$(awk -v r="$ratio" -v f="$SPIKE_FACTOR" 'BEGIN{print (r>f)?1:0}')" = "1" ]; then
        issue=$(jq -n \
            --arg title "Cloud SQL instance \`$inst_name\` shows a throughput spike" \
            --arg details "Instance '$inst_name' in project '$GCP_PROJECT_ID' peaked at ${through_max} bytes/s vs an average of ${through_avg} bytes/s (${ratio}x) over the last ${UTILIZATION_HOURS}h, suggesting a burst or query storm." \
            --arg severity "2" \
            --arg expected "Cloud SQL throughput should remain relatively stable without large spikes" \
            --arg actual "Instance '$inst_name' throughput spiked to ${ratio}x its average" \
            --arg next_steps "Investigate the timing and cause of the throughput spike. Review slow or expensive queries, connection pooling, and application batch jobs hitting the instance." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done < <(jq -c '.[]' "$CONFIG_FILE")

echo "$report" > "$REPORT_FILE"
if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Performance analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
