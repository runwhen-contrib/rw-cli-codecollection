#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ENV_NAME
#   GOOGLE_APPLICATION_CREDENTIALS
#
# OPTIONAL ENV VARS:
#   LOOKBACK_WINDOW_MINUTES (default 1440)
#   QUEUE_BACKLOG_THRESHOLD (default 100) - avg queue depth that indicates a
#     persistent backlog / insufficient scheduler/worker capacity.
#   QUEUE_BACKLOG_PERCENT_OF_TIME (default 30) - % of window above the
#     threshold before flagging.
#   SCHEDULER_HEARTBEAT_MIN (default 0) - minimum scheduler heartbeats expected
#     over the window; 0 disables this check.
#
# Measures scheduler heartbeat count and the task queue depth over
# the window and flags scheduler saturation or persistent queue backlogs that
# indicate insufficient capacity.
#
# Writes a JSON array of issues to OUTPUT_FILE (default
# scheduler_queue_issues.json).
# -----------------------------------------------------------------------------

GCP_PROJECT_ID="${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:?Must set ENV_NAME}"
LOOKBACK_WINDOW_MINUTES="${LOOKBACK_WINDOW_MINUTES:-1440}"
QUEUE_BACKLOG_THRESHOLD="${QUEUE_BACKLOG_THRESHOLD:-100}"
QUEUE_BACKLOG_PERCENT_OF_TIME="${QUEUE_BACKLOG_PERCENT_OF_TIME:-30}"
SCHEDULER_HEARTBEAT_MIN="${SCHEDULER_HEARTBEAT_MIN:-0}"
OUTPUT_FILE="${OUTPUT_FILE:-scheduler_queue_issues.json}"

BASE_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${BASE_DIR}/composer_metrics_common.sh"

issues='[]'

queue_query=$(cat <<MQL
fetch composer.googleapis.com/environment/task_queue_length
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
)

heartbeat_query=$(cat <<MQL
fetch composer.googleapis.com/environment/scheduler_heartbeat_count
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| group_by [resource.environment_name]
MQL
)

queue_values=$(mql_query "$queue_query" | extract_point_values)
heartbeat_values=$(mql_query "$heartbeat_query" | extract_point_values)

queue_stats=$(points_stats "$queue_values")
queue_avg=$(printf '%s' "$queue_stats" | jq -r '.avg')
queue_max=$(printf '%s' "$queue_stats" | jq -r '.max')
queue_count=$(printf '%s' "$queue_stats" | jq -r '.count')
queue_pct_above=$(pct_above "$queue_values" "$QUEUE_BACKLOG_THRESHOLD")

heartbeat_total=$(printf '%s' "$heartbeat_values" | jq 'add // 0')

echo "Scheduler and queue analysis for '${ENV_NAME}' (last ${LOOKBACK_WINDOW_MINUTES}m):"
echo "  Queue depth: avg=${queue_avg} max=${queue_max} (${queue_count} samples)"
echo "  Queue % of time above ${QUEUE_BACKLOG_THRESHOLD}: ${queue_pct_above}%"
echo "  Scheduler heartbeats over window: ${heartbeat_total}"

if [ "$queue_count" -gt 0 ]; then
    backlog=$(jq -n \
        --argjson avg "$queue_avg" \
        --argjson pct "$queue_pct_above" \
        --argjson thr "$QUEUE_BACKLOG_THRESHOLD" \
        --argjson timepct "$QUEUE_BACKLOG_PERCENT_OF_TIME" \
        '($avg >= $thr) or ($pct >= $timepct)')
    if [ "$backlog" = "true" ]; then
        issues=$(add_issue \
            "$issues" \
            "Persistent Cloud Composer task queue backlog in '${ENV_NAME}'" \
            "The task queue for environment '${ENV_NAME}' averaged ${queue_avg} (max ${queue_max}) over the last ${LOOKBACK_WINDOW_MINUTES}m, above the ${QUEUE_BACKLOG_THRESHOLD} backlog threshold ${queue_pct_above}% of the time. A persistent backlog indicates scheduler/worker capacity cannot keep up with generated tasks." \
            "3" \
            "The task queue should be consistently drained below the ${QUEUE_BACKLOG_THRESHOLD} depth threshold." \
            "Task queue averaged ${queue_avg} with max ${queue_max} over the lookback window." \
            "Increase worker and/or scheduler capacity, reduce DAG parallelism, or review tasks that pile up. Investigate which DAGs are contributing to the queue depth.")
    fi
fi

if [ "${SCHEDULER_HEARTBEAT_MIN}" != "0" ]; then
    if [ "$heartbeat_total" -lt "$SCHEDULER_HEARTBEAT_MIN" ]; then
        issues=$(add_issue \
            "$issues" \
            "Cloud Composer scheduler under-reporting heartbeats for '${ENV_NAME}'" \
            "The scheduler for environment '${ENV_NAME}' produced only ${heartbeat_total} heartbeats over the last ${LOOKBACK_WINDOW_MINUTES}m, below the configured minimum of ${SCHEDULER_HEARTBEAT_MIN}. A stalled or saturated scheduler cannot keep up with task scheduling." \
            "3" \
            "The scheduler should produce at least ${SCHEDULER_HEARTBEAT_MIN} heartbeats over the window." \
            "Scheduler produced ${heartbeat_total} heartbeats over the lookback window." \
            "Investigate scheduler stability (logs, DAG parsing time) and increase scheduler count or core/lower down DAG parsing load.")
    fi
fi

printf '%s' "$issues" > "$OUTPUT_FILE"
echo "Scheduler and queue analysis complete. Results in ${OUTPUT_FILE}"