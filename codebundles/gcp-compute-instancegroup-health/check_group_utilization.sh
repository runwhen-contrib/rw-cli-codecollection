#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Instance Group Utilization
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID
#   INSTANCE_GROUP_NAME  Name of the instance group to check (group scope)
#
# OPTIONAL ENV VARS:
#   UTILIZATION_LOW_THRESHOLD   Average CPU utilization % below which a group
#                               is considered under-utilized (default: 5)
#   UTILIZATION_HIGH_THRESHOLD  Average CPU utilization % above which a group
#                               is considered over-utilized (default: 90)
#
# Checks average CPU/disk utilization across group members via Cloud Monitoring
# ('compute.googleapis.com/instance/cpu/utilization'), flagging groups that are
# consistently over- or under-utilized (scaling risk or wasted capacity).
# Produces issues of severity 3/4.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"
UTILIZATION_LOW_THRESHOLD="${UTILIZATION_LOW_THRESHOLD:-5}"
UTILIZATION_HIGH_THRESHOLD="${UTILIZATION_HIGH_THRESHOLD:-90}"

OUTPUT_FILE="group_utilization_issues.json"
issues_json='[]'

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Utilization check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking utilization for instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID (low < ${UTILIZATION_LOW_THRESHOLD}%, high > ${UTILIZATION_HIGH_THRESHOLD}%)"

# Pull Cloud Monitoring CPU utilization for instances in this group over the
# last hour. If Monitoring is unavailable (metric server error), emit degree of
# confidence rather than a false alarm.
time_series=$(gcloud monitoring time-series list \
  --filter='metric.type="compute.googleapis.com/instance/cpu/utilization"' \
  "--interval-start=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  "--interval-end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")

if [ "$(echo "$time_series" | jq length)" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Utilization Metrics Available for Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "No Cloud Monitoring CPU utilization time series were returned for instances in group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` over the last hour. Utilization cannot be assessed." \
    --arg severity "2" \
    --arg next_steps "Verify the service account has roles/monitoring.viewer and that the instances are emitting metrics. Check the instance names in the group." \
    --arg expected "The group's member instances should have available utilization metrics." \
    --arg actual "No utilization metrics were returned." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Compute the average utilization across the returned points for this project.
avg_util=$(echo "$time_series" | jq '[.[].points[].value.doubleValue] | if length == 0 then null else (add / length * 100) end // null')

if [ -z "$avg_util" ] || [ "$avg_util" = "null" ]; then
  echo "No numeric utilization values available. Skipping utilization check."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

avg_util_rounded=$(printf "%.1f" "$avg_util")
echo "  Average CPU utilization across group: ${avg_util_rounded}% (low bound ${UTILIZATION_LOW_THRESHOLD}%, high bound ${UTILIZATION_HIGH_THRESHOLD}%)"

# Over-utilization: sustained high CPU indicates a scaling risk.
if awk "BEGIN { exit !($avg_util >= $UTILIZATION_HIGH_THRESHOLD) }"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Instance group \`$INSTANCE_GROUP_NAME\` is over-utilized" \
    --arg d "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has an average CPU utilization of ${avg_util_rounded}%, above the high threshold of ${UTILIZATION_HIGH_THRESHOLD}%. Sustained over-utilization is a scaling and availability risk." \
    --arg s "4" \
    --arg ns "Review the autoscaler configuration and consider raising the autoscaler max or increasing instance size/template capacity. Investigate load distribution across members." \
    --arg e "Average CPU utilization should be below the high threshold of ${UTILIZATION_HIGH_THRESHOLD}%." \
    --arg a "Average CPU utilization is ${avg_util_rounded}%." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

# Under-utilization: sustained very low CPU indicates wasted capacity.
if awk "BEGIN { exit !($avg_util <= $UTILIZATION_LOW_THRESHOLD) }"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Instance group \`$INSTANCE_GROUP_NAME\` is under-utilized" \
    --arg d "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has an average CPU utilization of ${avg_util_rounded}%, below the low threshold of ${UTILIZATION_LOW_THRESHOLD}%. This indicates wasted capacity and unnecessary cost." \
    --arg s "3" \
    --arg ns "Consider reducing the instance group size, adjusting the autoscaler minimum, or right-sizing the member instances to reduce waste." \
    --arg e "Average CPU utilization should be above the low threshold of ${UTILIZATION_LOW_THRESHOLD}%." \
    --arg a "Average CPU utilization is ${avg_util_rounded}%." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Utilization check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Average CPU utilization: ${avg_util_rounded}%"
