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

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"
UTILIZATION_LOW_THRESHOLD="${UTILIZATION_LOW_THRESHOLD:-5}"
UTILIZATION_HIGH_THRESHOLD="${UTILIZATION_HIGH_THRESHOLD:-90}"

OUTPUT_FILE="group_utilization_issues.json"
issues_json='[]'

# Start from a clean slate so a previous run's findings cannot leak into this
# one, and make any unexpected failure surface as an issue: an empty issue file
# would otherwise be read as "healthy".
echo '[]' > "$OUTPUT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Utilization Check Failed for \`$INSTANCE_GROUP_NAME\`" \
    --arg d "The utilization check script exited with code $rc for instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Utilization could not be assessed." \
    --arg ns "Confirm the service account has roles/monitoring.viewer and roles/compute.viewer, then re-run the check." \
    --arg e "The utilization check should complete and report the group's average CPU utilization." \
    --arg a "The utilization check failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Utilization check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking utilization for instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID (low < ${UTILIZATION_LOW_THRESHOLD}%, high > ${UTILIZATION_HIGH_THRESHOLD}%)"

# Resolve the group location and its member instances. Utilization must be
# measured for this group's members only, not for every VM in the project.
zone=$(gcloud compute instance-groups list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(zone)" --project="$GCP_PROJECT_ID" | head -1 | sed 's#.*/##')
region=$(gcloud compute instance-groups list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(region)" --project="$GCP_PROJECT_ID" | head -1 | sed 's#.*/##')

if [ -n "$zone" ] && [ "$zone" != "null" ]; then
  LOCATION_FLAG="--zone"; LOCATION="$zone"
elif [ -n "$region" ] && [ "$region" != "null" ]; then
  LOCATION_FLAG="--region"; LOCATION="$region"
else
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Locate Instance Group \`$INSTANCE_GROUP_NAME\` for Utilization" \
    --arg details "Instance group \`$INSTANCE_GROUP_NAME\` could not be located in project \`$GCP_PROJECT_ID\`, so its utilization cannot be measured." \
    --arg severity "3" \
    --arg next_steps "Verify the group name and project with 'gcloud compute instance-groups list --project=$GCP_PROJECT_ID'." \
    --arg expected "The instance group should exist and be locatable." \
    --arg actual "The instance group could not be located." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

member_names=$(gcloud compute instance-groups list-instances "$INSTANCE_GROUP_NAME" \
  $LOCATION_FLAG "$LOCATION" --format="value(instance)" --project="$GCP_PROJECT_ID" \
  | sed 's#.*/##')

if [ -z "$member_names" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Instance Group \`$INSTANCE_GROUP_NAME\` Has No Members to Measure" \
    --arg details "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has no member instances, so there is no utilization to measure." \
    --arg severity "3" \
    --arg next_steps "Investigate why the group is empty: review the instance template, autoscaler bounds, and recent resize operations." \
    --arg expected "The instance group should have at least one member instance emitting utilization metrics." \
    --arg actual "The instance group has no member instances." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Build a Monitoring filter scoped to the member instance IDs. The Monitoring
# REST API is used directly because gcloud has no 'monitoring time-series'
# command. Points are aligned per series before they are averaged, so one noisy
# series cannot dominate the group average.
instance_ids=$(gcloud compute instances list \
  --filter="name=($(echo "$member_names" | tr '\n' ',' | sed 's/,$//' | tr ',' ' '))" \
  --format="value(id)" --project="$GCP_PROJECT_ID")

id_filter=""
for id in $instance_ids; do
  if [ -z "$id_filter" ]; then
    id_filter="resource.labels.instance_id=\"$id\""
  else
    id_filter="$id_filter OR resource.labels.instance_id=\"$id\""
  fi
done

monitoring_filter="metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND ($id_filter)"
encoded_filter=$(jq -rn --arg v "$monitoring_filter" '$v | @uri')
start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
access_token=$(gcloud auth print-access-token)

response=$(curl -sS -H "Authorization: Bearer $access_token" \
  "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries?filter=${encoded_filter}&interval.startTime=${start_time}&interval.endTime=${end_time}&aggregation.alignmentPeriod=300s&aggregation.perSeriesAligner=ALIGN_MEAN")

api_error=$(echo "$response" | jq -r '.error.message // ""')
if [ -n "$api_error" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cloud Monitoring Query Failed for Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "The Cloud Monitoring API rejected the CPU utilization query for group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`: $api_error" \
    --arg severity "2" \
    --arg next_steps "Grant the service account roles/monitoring.viewer and confirm the Monitoring API is enabled: 'gcloud services enable monitoring.googleapis.com --project=$GCP_PROJECT_ID'." \
    --arg expected "The Cloud Monitoring API should return CPU utilization time series for the group members." \
    --arg actual "The Cloud Monitoring API returned an error." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

time_series=$(echo "$response" | jq '.timeSeries // []')

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

# Average each member's own series first, then average across members, so a
# member reporting more points than the others cannot skew the group figure.
avg_util=$(echo "$time_series" | jq '
  [ .[]
    | [ .points[]?.value.doubleValue ]
    | select(length > 0)
    | (add / length)
  ]
  | if length == 0 then null else (add / length * 100) end')

if [ -z "$avg_util" ] || [ "$avg_util" = "null" ]; then
  echo "No numeric utilization values available. Skipping utilization check."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

avg_util_rounded=$(printf "%.1f" "$avg_util")
echo "  Average CPU utilization across group: ${avg_util_rounded}% (low bound ${UTILIZATION_LOW_THRESHOLD}%, high bound ${UTILIZATION_HIGH_THRESHOLD}%)"

# Over-utilization: sustained high CPU indicates a scaling risk. This is the
# more severe of the two bounds -- a saturated group is an availability risk
# right now, while an idle one only wastes money.
if awk "BEGIN { exit !($avg_util >= $UTILIZATION_HIGH_THRESHOLD) }"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Instance group \`$INSTANCE_GROUP_NAME\` is over-utilized" \
    --arg d "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has an average CPU utilization of ${avg_util_rounded}%, above the high threshold of ${UTILIZATION_HIGH_THRESHOLD}%. Sustained over-utilization is a scaling and availability risk." \
    --arg s "3" \
    --arg ns "Review the autoscaler configuration and consider raising the autoscaler max or increasing instance size/template capacity. Investigate load distribution across members." \
    --arg e "Average CPU utilization should be below the high threshold of ${UTILIZATION_HIGH_THRESHOLD}%." \
    --arg a "Average CPU utilization is ${avg_util_rounded}%." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

# Under-utilization: sustained very low CPU indicates wasted capacity. It is a
# cost finding, not a health one, so it is informational: an idle group is
# serving everything asked of it and must not be scored as unhealthy.
if awk "BEGIN { exit !($avg_util <= $UTILIZATION_LOW_THRESHOLD) }"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Instance group \`$INSTANCE_GROUP_NAME\` is under-utilized" \
    --arg d "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has an average CPU utilization of ${avg_util_rounded}%, below the low threshold of ${UTILIZATION_LOW_THRESHOLD}%. This indicates wasted capacity and unnecessary cost." \
    --arg s "4" \
    --arg ns "Consider reducing the instance group size, adjusting the autoscaler minimum, or right-sizing the member instances to reduce waste." \
    --arg e "Average CPU utilization should be above the low threshold of ${UTILIZATION_LOW_THRESHOLD}%." \
    --arg a "Average CPU utilization is ${avg_util_rounded}%." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Utilization check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Average CPU utilization: ${avg_util_rounded}%"
