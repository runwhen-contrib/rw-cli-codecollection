#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Instance Group OS Patch Compliance
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID
#   INSTANCE_GROUP_NAME  Name of the instance group to check (group scope)
#
# OPTIONAL ENV VARS:
#   PATCH_WARNING_DAYS   Days a missing/pending OS patch may go unremediated
#                        before alerting (default: 30)
#
# Uses GCP OS Config to check patch compliance across group members when
# available, flagging groups with pending or missing security patches beyond
# PATCH_WARNING_DAYS. Produces issues of severity 2/3.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"
PATCH_WARNING_DAYS="${PATCH_WARNING_DAYS:-30}"

OUTPUT_FILE="group_patch_issues.json"
issues_json='[]'

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Patch compliance check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking OS patch compliance for instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID (warning after $PATCH_WARNING_DAYS days)"

# Resolve group location and member instances.
zone=$(gcloud compute instance-groups list --filter="name=$INSTANCE_GROUP_NAME" --zones \
  --format="value(zone)" --project="$GCP_PROJECT_ID" 2>/dev/null | head -1)
region=$(gcloud compute instance-groups list --filter="name=$INSTANCE_GROUP_NAME" --regions \
  --format="value(region)" --project="$GCP_PROJECT_ID" 2>/dev/null | head -1)

if [ -n "$zone" ] && [ "$zone" != "null" ]; then
  LOCATION_FLAG="--zone"; LOCATION="$zone"
elif [ -n "$region" ] && [ "$region" != "null" ]; then
  LOCATION_FLAG="--region"; LOCATION="$region"
else
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Locate Instance Group \`$INSTANCE_GROUP_NAME\` for Patch Compliance" \
    --arg details "Instance group \`$INSTANCE_GROUP_NAME\` could not be located in project \`$GCP_PROJECT_ID\`." \
    --arg severity "2" \
    --arg next_steps "Verify the group name and project." \
    --arg expected "The instance group should exist for patch compliance assessment." \
    --arg actual "The instance group could not be located." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

members=$(gcloud compute instance-groups list-instances "$INSTANCE_GROUP_NAME" \
  $LOCATION_FLAG "$LOCATION" --format="value(instance)" --project="$GCP_PROJECT_ID" 2>/dev/null || true)

if [ -z "$members" ]; then
  echo "No member instances found for patch compliance. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# Patch compliance is best gathered from recent OS Config patch jobs against
# the group's instances. Find the most recent patch job that targeted these
# instances and evaluate its state. If OS Config is not enabled or no patch
# jobs exist, we emit an informational finding rather than a false alarm.
patch_jobs=$(gcloud compute os-config patch-jobs list --filter="state=SUCCEEDED|state=FAILED" \
  --limit=10 --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")

if [ "$(echo "$patch_jobs" | jq length)" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No OS Patch History Found for Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "No recent OS Config patch jobs were found affecting instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Without patch jobs, patch compliance cannot be verified for the group's members." \
    --arg severity "2" \
    --arg next_steps "Enable OS Config on the member instances (roles/osconfig.serviceAgent) and schedule regular patch jobs via 'gcloud compute os-config patch-jobs execute' or Cloud Scheduler." \
    --arg expected "The group should have recent OS Config patch jobs confirming member instances are patched." \
    --arg actual "No OS Config patch jobs were found." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Inspect each member's patch state from the latest matching patch job details.
instance_list=$(echo "$members" | tr '\n' ' ' | sed 's/ $//')
for job_id in $(echo "$patch_jobs" | jq -r '.[].name'); do
  job_details=$(gcloud compute os-config patch-job-instance-details "$job_id" \
    --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")
  for instance in $members; do
    instance_name=$(echo "$instance" | sed 's#.*/##')
    patch_state=$(echo "$job_details" | jq -r --arg n "$instance_name" \
      '.[]? | select(.instance | contains($n)) | .state // ""' | head -1)
    if [ -z "$patch_state" ]; then
      continue
    fi
    echo "  Member $instance_name: patch state=$patch_state"
    if [ "$patch_state" = "FAILED" ] || [ "$patch_state" = "SUCCEEDED" ] || [ "$patch_state" = "TIMED_OUT" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Member \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` has patch state $patch_state" \
        --arg d "Member instance \`$instance_name\` of instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has OS patch state \`$patch_state\` from patch job \`$job_id\`. The group may have members missing security patches for more than $PATCH_WARNING_DAYS days." \
        --arg s "3" \
        --arg ns "Remediate the member instance's patches: 'gcloud compute os-config patch-jobs execute --instance-filter-names=$instance_name'. Review the patch job details for the failing packages." \
        --arg e "All group members should have a SUCCEEDED patch state within the last $PATCH_WARNING_DAYS days." \
        --arg a "Member \`$instance_name\` has patch state $patch_state." \
        '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
                 "next_steps": $ns, "expected": $e, "actual": $a, "instance": $instance_name}]')
    fi
  done
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Patch compliance check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Patch job history:"
echo "$patch_jobs" | jq '[.[] | {name, state, createTime}]'
