#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ENV_NAME            (Composer environment to analyze)
#   GOOGLE_APPLICATION_CREDENTIALS
#
# OPTIONAL ENV VARS:
#   LOOKBACK_WINDOW_MINUTES (default 1440)
#   UTILIZATION_THRESHOLD_PERCENT (default 80) - upper saturation threshold
#   SATURATION_PERCENT_OF_TIME (default 50) - % of window above threshold to flag
#
# Queries environment workload CPU quota utilization and running executor
# task count over the lookback window from Cloud Monitoring, flagging
# environments that are consistently saturated (over-provisioned handling
# is done in a separate task).
#
# Writes a JSON array of issues to OUTPUT_FILE (default
# worker_utilization_issues.json).
# -----------------------------------------------------------------------------

GCP_PROJECT_ID="${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:?Must set ENV_NAME}"
LOOKBACK_WINDOW_MINUTES="${LOOKBACK_WINDOW_MINUTES:-1440}"
UTILIZATION_THRESHOLD_PERCENT="${UTILIZATION_THRESHOLD_PERCENT:-80}"
SATURATION_PERCENT_OF_TIME="${SATURATION_PERCENT_OF_TIME:-50}"
OUTPUT_FILE="${OUTPUT_FILE:-worker_utilization_issues.json}"

BASE_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${BASE_DIR}/composer_metrics_common.sh"

issues='[]'

cpu_usage_query=$(cat <<MQL
fetch composer.googleapis.com/environment/workloads_cpu_quota_usage
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
)

cpu_quota_query=$(cat <<MQL
fetch composer.googleapis.com/environment/workloads_cpu_quota
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
)

running_tasks_query=$(cat <<MQL
fetch composer.googleapis.com/environment/executor/running_tasks
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
)

cpu_usage_values=$(mql_query "$cpu_usage_query" | extract_point_values)
cpu_quota_values=$(mql_query "$cpu_quota_query" | extract_point_values)
task_values=$(mql_query "$running_tasks_query" | extract_point_values)

cpu_values=$(jq -n \
    --argjson usage "$cpu_usage_values" \
    --argjson quota "$cpu_quota_values" \
    '[$usage, $quota] | map(select(length > 0)) | transpose | map(if .[1] > 0 then (.[0] / .[1] * 100) else 0 end)')

cpu_stats=$(points_stats "$cpu_values")
cpu_avg=$(printf '%s' "$cpu_stats" | jq -r '.avg')
cpu_max=$(printf '%s' "$cpu_stats" | jq -r '.max')
cpu_count=$(printf '%s' "$cpu_stats" | jq -r '.count')
cpu_pct_above=$(pct_above "$cpu_values" "$UTILIZATION_THRESHOLD_PERCENT")

task_stats=$(points_stats "$task_values")
task_avg=$(printf '%s' "$task_stats" | jq -r '.avg')

echo "Workload utilization analysis for '${ENV_NAME}' (last ${LOOKBACK_WINDOW_MINUTES}m):"
echo "  CPU utilization (workload quota usage/limit): avg=${cpu_avg}% max=${cpu_max}% (${cpu_count} samples)"
echo "  CPU % of time above ${UTILIZATION_THRESHOLD_PERCENT}%: ${cpu_pct_above}%"
echo "  Running Celery tasks avg: ${task_avg}"

if [ "$cpu_count" -gt 0 ]; then
    above_threshold=$(jq -n --argjson a "$cpu_avg" --argjson t "$UTILIZATION_THRESHOLD_PERCENT" \
        '$a >= $t')
    consistently_above=$(jq -n --argjson p "$cpu_pct_above" --argjson s "$SATURATION_PERCENT_OF_TIME" \
        '$p >= $s')
    if [ "$above_threshold" = "true" ] || [ "$consistently_above" = "true" ]; then
        issues=$(add_issue \
            "$issues" \
            "Cloud Composer workload CPU saturation in '${ENV_NAME}'" \
            "Workload CPU utilization for environment '${ENV_NAME}' averaged ${cpu_avg}% (max ${cpu_max}%) over the last ${LOOKBACK_WINDOW_MINUTES}m. Utilization was above the ${UTILIZATION_THRESHOLD_PERCENT}% threshold ${cpu_pct_above}% of the time. Saturated workers can queue tasks, increase task latency, and slow scheduling." \
            "3" \
            "Workload CPU utilization should remain below ${UTILIZATION_THRESHOLD_PERCENT}% to avoid task backlogs." \
            "Workload CPU averaged ${cpu_avg}% with ${cpu_max}% peak over the lookback window." \
            "Add worker capacity (increase worker count/CPU) or move to a larger Composer environment. Review DAG concurrency and Celery worker parameters.")
    fi
fi

printf '%s' "$issues" > "$OUTPUT_FILE"
echo "Worker utilization analysis complete. Results in ${OUTPUT_FILE}"