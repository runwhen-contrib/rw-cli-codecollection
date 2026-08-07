#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Lightweight SLI computation for Cloud Composer performance. Produces a 0-1
# health score from three binary dimensions that must complete in < 30s.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   GOOGLE_APPLICATION_CREDENTIALS
#
# OPTIONAL ENV VARS:
#   ENV_NAME (default "All")
#   SLI_WINDOW_MINUTES (default 60)
#   UTILIZATION_THRESHOLD_PERCENT (default 80)
#   UNDERUTILIZATION_THRESHOLD_PERCENT (default 20)
#   QUEUE_BACKLOG_THRESHOLD (default 100)
#
# Outputs a JSON object to OUTPUT_FILE (default composer_sli.json):
# {
#   "worker_capacity": <0-1>,   // workers are not saturated
#   "queue_health": <0-1>,      // task queue is not backlogged
#   "utilization_balance": <0-1>, // not over-provisioned (idle)
#   "health_score": <0-1>       // arithmetic mean of the three dimensions
# }
# -----------------------------------------------------------------------------

GCP_PROJECT_ID="${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:-All}"
SLI_WINDOW_MINUTES="${SLI_WINDOW_MINUTES:-60}"
UTILIZATION_THRESHOLD_PERCENT="${UTILIZATION_THRESHOLD_PERCENT:-80}"
UNDERUTILIZATION_THRESHOLD_PERCENT="${UNDERUTILIZATION_THRESHOLD_PERCENT:-20}"
QUEUE_BACKLOG_THRESHOLD="${QUEUE_BACKLOG_THRESHOLD:-100}"
OUTPUT_FILE="${OUTPUT_FILE:-composer_sli.json}"

BASE_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${BASE_DIR}/composer_metrics_common.sh"

# Resolve environment list (All -> discover, otherwise single env)
if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "all" ]; then
    envs_json=$(jq -n --arg e "$ENV_NAME" '[$e]')
else
    if ! envs=$(gcloud composer environments list --project "${GCP_PROJECT_ID}" --format="json" 2>/dev/null); then
        envs='[]'
    fi
    envs_json=$(printf '%s' "$envs" | jq -c '[.[] | .name // empty]')
fi

env_count=$(printf '%s' "$envs_json" | jq 'length')
if [ "$env_count" -eq 0 ]; then
    jq -n \
        --argjson wc 1.0 --argjson qh 1.0 --argjson ub 1.0 \
        '{worker_capacity: $wc, queue_health: $qh, utilization_balance: $ub, health_score: 1.0}' > "$OUTPUT_FILE"
    echo "No Composer environments to monitor; health 1.0"
    exit 0
fi

wc_sum=0
qh_sum=0
ub_sum=0

for env in $(printf '%s' "$envs_json" | jq -r '.[]'); do
    cpu_values=$(mql_query "$(
        cat <<MQL
fetch composer.googleapis.com/environment/worker/utilization
| filter resource.environment_name == '${env}'
| within ${SLI_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
    )" | extract_point_values)

    queue_values=$(mql_query "$(
        cat <<MQL
fetch composer.googleapis.com/environment/database/queue_size
| filter resource.environment_name == '${env}'
| within ${SLI_WINDOW_MINUTES}m
| every 5m
| group_by [resource.environment_name]
MQL
    )" | extract_point_values)

    cpu_avg=$(printf '%s' "$cpu_values" | jq 'if length>0 then add/length else 0 end')
    cpu_pct_above=$(pct_above "$cpu_values" "$UTILIZATION_THRESHOLD_PERCENT")
    queue_avg=$(printf '%s' "$queue_values" | jq 'if length>0 then add/length else 0 end')

    # Dimensions: 1 = healthy, 0 = degraded
    wc=$(jq -n --argjson avg "$cpu_avg" --argjson thr "$UTILIZATION_THRESHOLD_PERCENT" --argjson pct "$cpu_pct_above" \
        'if (($avg >= $thr) or ($pct >= 50)) then 0 else 1 end')
    qh=$(jq -n --argjson avg "$queue_avg" --argjson thr "$QUEUE_BACKLOG_THRESHOLD" \
        'if ($avg >= $thr) then 0 else 1 end')
    ub=$(jq -n --argjson avg "$cpu_avg" --argjson under "$UNDERUTILIZATION_THRESHOLD_PERCENT" \
        'if ($avg < $under) then 0 else 1 end')

    wc_sum=$(jq -n --argjson a "$wc_sum" --argjson b "$wc" '$a + $b')
    qh_sum=$(jq -n --argjson a "$qh_sum" --argjson b "$qh" '$a + $b')
    ub_sum=$(jq -n --argjson a "$ub_sum" --argjson b "$ub" '$a + $b')
    echo "  ${env}: cpu=${cpu_avg}% queue=${queue_avg} -> capacity=${wc} queue=${qh} balance=${ub}"
done

wc=$(jq -n --argjson s "$wc_sum" --argjson n "$env_count" 'if $n>0 then $s/$n else 1 end')
qh=$(jq -n --argjson s "$qh_sum" --argjson n "$env_count" 'if $n>0 then $s/$n else 1 end')
ub=$(jq -n --argjson s "$ub_sum" --argjson n "$env_count" 'if $n>0 then $s/$n else 1 end')
health=$(jq -n --argjson a "$wc" --argjson b "$qh" --argjson c "$ub" '((($a + $b + $c) / 3) * 1000 | floor) / 1000')

jq -n --argjson wc "$wc" --argjson qh "$qh" --argjson ub "$ub" --argjson h "$health" \
    '{worker_capacity: $wc, queue_health: $qh, utilization_balance: $ub, health_score: $h}' > "$OUTPUT_FILE"

echo "SLI health score: ${health}"
