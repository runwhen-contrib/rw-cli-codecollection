#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ENV_NAME
#   GOOGLE_APPLICATION_CREDENTIALS
#
# OPTIONAL ENV VARS:
#   LOOKBACK_WINDOW_MINUTES (default 1440)   - the "current" comparison window
#   BASELINE_WINDOW_MINUTES (default 10080)  - the rolling "normal" baseline
#   DELTA_THRESHOLD_PERCENT (default 50)     - % deviation that triggers an issue
#   DELTA_MIN_ABSOLUTE (default 1)           - minimum absolute change to avoid
#     flagging on negligible utilizations (e.g. 0 -> 0.5)
#
# Compares current workload CPU utilization and task queue depth against the
# rolling baseline (computed from the same environment's history) over the
# configurable windows, flagging significant deltas (sudden spikes or sustained
# growth) that deviate from 'normal' usage.
#
# Writes a JSON array of issues to OUTPUT_FILE (default
# usage_delta_issues.json).
# -----------------------------------------------------------------------------

GCP_PROJECT_ID="${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:?Must set ENV_NAME}"
LOOKBACK_WINDOW_MINUTES="${LOOKBACK_WINDOW_MINUTES:-1440}"
BASELINE_WINDOW_MINUTES="${BASELINE_WINDOW_MINUTES:-10080}"
DELTA_THRESHOLD_PERCENT="${DELTA_THRESHOLD_PERCENT:-50}"
DELTA_MIN_ABSOLUTE="${DELTA_MIN_ABSOLUTE:-1}"
OUTPUT_FILE="${OUTPUT_FILE:-usage_delta_issues.json}"

BASE_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${BASE_DIR}/composer_metrics_common.sh"

issues='[]'

# Helper: build MQL for a given metric over a given window
build_window_query() {
    local metric="$1" window="$2"
    cat <<MQL
fetch cloud_composer_environment::composer.googleapis.com/${metric}
| filter resource.environment_name == '${ENV_NAME}'
| within ${window}m
| every 5m
| group_by [resource.environment_name]
MQL
}

# Compute average value of a single metric over a window
single_avg() {
    local metric="$1" window="$2"
    mql_query "$(build_window_query "$metric" "$window")" | extract_point_values | jq 'if length>0 then add/length else 0 end'
}

# Compute CPU utilization ratio (workloads_cpu_quota_usage / workloads_cpu_quota) as percentage
cpu_ratio_avg() {
    local window="$1"
    local usage_values quota_values
    usage_values=$(mql_query "$(build_window_query "environment/workloads_cpu_quota_usage" "$window")" | extract_point_values)
    quota_values=$(mql_query "$(build_window_query "environment/workloads_cpu_quota" "$window")" | extract_point_values)
    local usage_avg quota_avg
    usage_avg=$(printf '%s' "$usage_values" | jq 'if length>0 then add/length else 0 end')
    quota_avg=$(printf '%s' "$quota_values" | jq 'if length>0 then add/length else 0 end')
    jq -n --argjson u "$usage_avg" --argjson q "$quota_avg" 'if $q > 0 then ($u / $q * 100) else 0 end'
}

# -- Workload CPU utilization delta --
cpu_current=$(cpu_ratio_avg "$LOOKBACK_WINDOW_MINUTES")
cpu_baseline=$(cpu_ratio_avg "$BASELINE_WINDOW_MINUTES")

# -- Queue depth delta --
queue_current=$(single_avg "environment/task_queue_length" "$LOOKBACK_WINDOW_MINUTES")
queue_baseline=$(single_avg "environment/task_queue_length" "$BASELINE_WINDOW_MINUTES")

cpu_current_r=$(printf '%.2f' "$cpu_current")
cpu_baseline_r=$(printf '%.2f' "$cpu_baseline")
queue_current_r=$(printf '%.2f' "$queue_current")
queue_baseline_r=$(printf '%.2f' "$queue_baseline")

echo "=== Usage Delta Analysis: ${ENV_NAME} ==="
echo "Current window: ${LOOKBACK_WINDOW_MINUTES} minutes"
echo "Baseline window: ${BASELINE_WINDOW_MINUTES} minutes"
echo "Delta threshold: ${DELTA_THRESHOLD_PERCENT}% (flagged if deviation from baseline exceeds threshold, with a minimum absolute change of ${DELTA_MIN_ABSOLUTE})"
echo ""
echo "Workload CPU utilization:"
echo "  current: ${cpu_current_r}%"
echo "  baseline: ${cpu_baseline_r}%"
echo ""
echo "Task queue depth (task_queue_length):"
echo "  current: ${queue_current_r}"
echo "  baseline: ${queue_baseline_r}"
echo ""

# Only flag when baseline is meaningful enough to compute a deviation and the
# absolute movement is above a minimum to avoid noise on near-zero values.
cpu_deviation=$(jq -n \
    --argjson cur "$cpu_current" \
    --argjson base "$cpu_baseline" \
    --argjson thr "$DELTA_THRESHOLD_PERCENT" \
    --argjson minabs "$DELTA_MIN_ABSOLUTE" \
    'if $base > 0 then (($cur - $base) / $base * 100) else (if $cur > $minabs then 999 else 0 end) end')

cpu_flag=$(jq -n \
    --argjson dev "$cpu_deviation" \
    --argjson cur "$cpu_current" \
    --argjson base "$cpu_baseline" \
    --argjson thr "$DELTA_THRESHOLD_PERCENT" \
    --argjson minabs "$DELTA_MIN_ABSOLUTE" \
    '(($dev | fabs) >= $thr) and ((($cur - $base) | fabs) >= $minabs)')

if [ "$cpu_flag" = "true" ]; then
    issues=$(add_issue \
        "$issues" \
        "Cloud Composer workload CPU utilization delta vs baseline in '${ENV_NAME}'" \
        "Workload CPU utilization for environment '${ENV_NAME}' changed from a ${BASELINE_WINDOW_MINUTES}m baseline of ${cpu_baseline_r}% to ${cpu_current_r}% over the last ${LOOKBACK_WINDOW_MINUTES}m (${cpu_deviation}% deviation, threshold ${DELTA_THRESHOLD_PERCENT}%). This is a significant deviation from 'normal' usage and may indicate changed workload." \
        "2" \
        "Current workload CPU utilization should remain within ${DELTA_THRESHOLD_PERCENT}% of the environment's rolling baseline." \
        "Workload CPU utilization moved ${cpu_deviation}% vs baseline (${cpu_baseline_r}% -> ${cpu_current_r}%)." \
        "Investigate what changed (new DAGs, schedule changes, upstream data dependencies). If sustained growth, plan capacity accordingly; if a spike, review what triggered it.")
fi

queue_flag=$(jq -n \
    --argjson cur "$queue_current" \
    --argjson base "$queue_baseline" \
    --argjson thr "$DELTA_THRESHOLD_PERCENT" \
    --argjson minabs "$DELTA_MIN_ABSOLUTE" \
    'if $base > 0 then ((($cur - $base) / $base * 100) | fabs) >= $thr else false end')

if [ "$queue_flag" = "true" ]; then
    issues=$(add_issue \
        "$issues" \
        "Cloud Composer queue depth delta vs baseline in '${ENV_NAME}'" \
        "Task queue depth for environment '${ENV_NAME}' changed from a ${BASELINE_WINDOW_MINUTES}m baseline of ${queue_baseline_r} to ${queue_current_r} over the last ${LOOKBACK_WINDOW_MINUTES}m, exceeding the ${DELTA_THRESHOLD_PERCENT}% delta threshold. The increase in queue depth signals growing task backlogs relative to normal." \
        "3" \
        "Current queue depth should remain within ${DELTA_THRESHOLD_PERCENT}% of the environment's rolling baseline." \
        "Queue depth moved from baseline ${queue_baseline_r} to ${queue_current_r}." \
        "Investigate upstream task generation. If the delta is sustained, add scheduler/worker capacity.")
fi

verdict="HEALTHY"
if [ "$cpu_flag" = "true" ]; then verdict="CPU DELTA DETECTED"; fi
if [ "$queue_flag" = "true" ]; then verdict="${verdict}, QUEUE DELTA DETECTED"; fi
echo "Verdict: ${verdict}"

printf '%s' "$issues" > "$OUTPUT_FILE"
echo "Usage delta analysis complete: $(jq length "$OUTPUT_FILE") issue(s) found."