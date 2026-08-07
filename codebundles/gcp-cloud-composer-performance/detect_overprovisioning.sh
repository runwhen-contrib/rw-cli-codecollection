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
#   UNDERUTILIZATION_THRESHOLD_PERCENT (default 20) - workers below this are idle
#   UNDERUTILIZATION_PERCENT_OF_TIME (default 80) - % of window below threshold
#     before flagging as over-provisioned.
#
# Flags environments that are consistently far below the worker/queue
# utilization threshold (idle capacity) over the window while still paying for
# that capacity, i.e. over-provisioned and eligible for scale-down.
#
# Writes a JSON array of issues to OUTPUT_FILE (default
# overprovisioning_issues.json).
# -----------------------------------------------------------------------------

GCP_PROJECT_ID="${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:?Must set ENV_NAME}"
LOOKBACK_WINDOW_MINUTES="${LOOKBACK_WINDOW_MINUTES:-1440}"
UNDERUTILIZATION_THRESHOLD_PERCENT="${UNDERUTILIZATION_THRESHOLD_PERCENT:-20}"
UNDERUTILIZATION_PERCENT_OF_TIME="${UNDERUTILIZATION_PERCENT_OF_TIME:-80}"
OUTPUT_FILE="${OUTPUT_FILE:-overprovisioning_issues.json}"

BASE_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${BASE_DIR}/composer_metrics_common.sh"

issues='[]'

cpu_query=$(cat <<MQL
fetch composer.googleapis.com/environment/worker/utilization
| filter resource.environment_name == '${ENV_NAME}'
| within ${LOOKBACK_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
)

cpu_values=$(mql_query "$cpu_query" | extract_point_values)
cpu_stats=$(points_stats "$cpu_values")
cpu_avg=$(printf '%s' "$cpu_stats" | jq -r '.avg')
cpu_count=$(printf '%s' "$cpu_stats" | jq -r '.count')
cpu_pct_below=$(pct_below "$cpu_values" "$UNDERUTILIZATION_THRESHOLD_PERCENT")

echo "Over-provisioning analysis for '${ENV_NAME}' (last ${LOOKBACK_WINDOW_MINUTES}m):"
echo "  Worker CPU avg: ${cpu_avg}% (${cpu_count} samples)"
echo "  CPU % of time below ${UNDERUTILIZATION_THRESHOLD_PERCENT}%: ${cpu_pct_below}%"

if [ "$cpu_count" -gt 0 ]; then
    idle=$(jq -n \
        --argjson avg "$cpu_avg" \
        --argjson pct "$cpu_pct_below" \
        --argjson ur "$UNDERUTILIZATION_THRESHOLD_PERCENT" \
        --argjson upt "$UNDERUTILIZATION_PERCENT_OF_TIME" \
        '($avg < $ur) and ($pct >= $upt)')
    if [ "$idle" = "true" ]; then
        issues=$(add_issue \
            "$issues" \
            "Cloud Composer environment '${ENV_NAME}' appears over-provisioned" \
            "Worker CPU utilization for environment '${ENV_NAME}' averaged ${cpu_avg}% over the last ${LOOKBACK_WINDOW_MINUTES}m and was below the ${UNDERUTILIZATION_THRESHOLD_PERCENT}% underutilization threshold ${cpu_pct_below}% of the time. The environment is consistently idle while capacity is still being paid for, making it a candidate for scale-down." \
            "2" \
            "Workers should run above the ${UNDERUTILIZATION_THRESHOLD_PERCENT}% underutilization threshold to justify capacity cost." \
            "Worker CPU utilization averaged ${cpu_avg}% and was below ${UNDERUTILIZATION_THRESHOLD_PERCENT}% for ${cpu_pct_below}% of the window." \
            "Consider scaling down the environment (reduce worker count, CPU/memory, or switch to a smaller environment size). Validate there are no seasonal peaks before resizing.")
    fi
fi

printf '%s' "$issues" > "$OUTPUT_FILE"
echo "Over-provisioning analysis complete. Results in ${OUTPUT_FILE}"
