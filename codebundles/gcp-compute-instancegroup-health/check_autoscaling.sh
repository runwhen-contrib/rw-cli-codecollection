#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Instance Group Autoscaling and Capacity
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID
#   INSTANCE_GROUP_NAME  Name of the managed instance group to check (group scope)
#
# For managed instance groups with autoscaling, verifies current size vs. target
# and flags autoscaler failures, unschedulable events, or groups unable to scale
# to meet demand. Produces issues of severity 3/4.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="group_autoscaling_issues.json"
issues_json='[]'

# Start from a clean slate so a previous run's findings cannot leak into this
# one, and make any unexpected failure surface as an issue: an empty issue file
# would otherwise be read as "healthy".
echo '[]' > "$OUTPUT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Autoscaling Check Failed for \`$INSTANCE_GROUP_NAME\`" \
    --arg d "The autoscaling and capacity check script exited with code $rc for instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Capacity could not be assessed." \
    --arg ns "Re-run 'gcloud compute instance-groups managed describe $INSTANCE_GROUP_NAME --project=$GCP_PROJECT_ID' manually and confirm the service account has roles/compute.viewer." \
    --arg e "The autoscaling check should complete and report the group's target size and autoscaler bounds." \
    --arg a "The autoscaling check failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Autoscaling check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking autoscaling and capacity for managed instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID"

# Resolve location of the managed group.
# gcloud reports the location as a full URL, so only the trailing name is kept.
zone=$(gcloud compute instance-groups managed list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(zone)" --project="$GCP_PROJECT_ID" | head -1 | sed 's#.*/##')
region=$(gcloud compute instance-groups managed list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(region)" --project="$GCP_PROJECT_ID" | head -1 | sed 's#.*/##')

if [ -n "$zone" ] && [ "$zone" != "null" ]; then
  LOCATION_FLAG="--zone"; LOCATION="$zone"
elif [ -n "$region" ] && [ "$region" != "null" ]; then
  LOCATION_FLAG="--region"; LOCATION="$region"
else
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Locate Managed Instance Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "Managed instance group \`$INSTANCE_GROUP_NAME\` could not be located in project \`$GCP_PROJECT_ID\`. It may be an unmanaged group or may not exist." \
    --arg severity "3" \
    --arg next_steps "Verify the group is a managed instance group and that the name and project are correct." \
    --arg expected "The managed instance group should exist." \
    --arg actual "The managed instance group could not be located." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Fetch the managed group description (targetSize, currentActions, state).
desc=$(gcloud compute instance-groups managed describe "$INSTANCE_GROUP_NAME" \
  $LOCATION_FLAG "$LOCATION" --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "{}")

if [ "$(echo "$desc" | jq length)" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Unable to Describe Instance Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "Failed to describe managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`." \
    --arg severity "4" \
    --arg next_steps "Verify the service account has roles/compute.viewer and that the group exists. Retry the describe command." \
    --arg expected "The managed instance group should be describable." \
    --arg actual "The describe call returned no data." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

target_size=$(echo "$desc" | jq -r '.targetSize // 0')
# The alternative operator must be parenthesised inside object construction.
current_actions=$(echo "$desc" | jq -c '{creating: (.currentActions.creating // 0), deleting: (.currentActions.deleting // 0), recreating: (.currentActions.recreating // 0), none: (.currentActions.none // 0)}')
state=$(echo "$desc" | jq -r '.state // "UNKNOWN"')

echo "  Target size: $target_size"
echo "  Current actions: $current_actions"

# A managed group stuck in a non-STABLE state (e.g. CREATING/STOPPING) cannot
# reliably serve capacity.
if [ "$state" != "STABLE" ] && [ "$state" != "UNKNOWN" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Managed instance group \`$INSTANCE_GROUP_NAME\` is in state $state" \
    --arg d "Managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` is in state \`$state\` (expected STABLE). A group not fully provisioned may not have the capacity to serve demand. Target size: $target_size; current actions: $current_actions." \
    --arg s "3" \
    --arg ns "Wait for the group to reach STABLE state, then re-check. Investigate any pending operations: 'gcloud compute operations list --filter=\"targetLink~$INSTANCE_GROUP_NAME\"'." \
    --arg e "The managed group should be in STABLE state with its full target capacity." \
    --arg a "The managed group is in state $state." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

# Evaluate the autoscaling policy. There is no
# 'gcloud compute instance-groups managed get-autoscaling-policy' subcommand:
# the describe output fetched above already carries the attached autoscaler
# under .autoscaler, so the policy is read from there and no second API call is
# made. A group with no autoscaler simply has no .autoscaler key.
autoscaler_status=$(echo "$desc" | jq -r '.autoscaler.status // ""')
min_size=$(echo "$desc" | jq -r '.autoscaler.autoscalingPolicy.minNumReplicas // 0')
max_size=$(echo "$desc" | jq -r '.autoscaler.autoscalingPolicy.maxNumReplicas // 0')
[[ "$min_size" =~ ^[0-9]+$ ]] || min_size=0
[[ "$max_size" =~ ^[0-9]+$ ]] || max_size=0

autoscaler_present="false"
if [ "$(echo "$desc" | jq 'has("autoscaler")')" = "true" ]; then
  autoscaler_present="true"
fi
echo "  Autoscaler present: $autoscaler_present (status=${autoscaler_status:-none} min=$min_size max=$max_size)"

# An autoscaler in ERROR cannot act on the group at all, so capacity is frozen
# wherever the last successful scaling action left it.
if [ "$autoscaler_present" = "true" ] && [ "$autoscaler_status" = "ERROR" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Autoscaler for instance group \`$INSTANCE_GROUP_NAME\` is in ERROR" \
    --arg d "The autoscaler attached to managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` reports status ERROR. The group cannot scale in or out while the autoscaler is failing, so capacity stays at its current size ($target_size) regardless of demand." \
    --arg s "3" \
    --arg ns "Inspect the autoscaler: 'gcloud compute instance-groups managed describe $INSTANCE_GROUP_NAME $LOCATION_FLAG=$LOCATION --project=$GCP_PROJECT_ID --format=\"value(autoscaler.statusDetails)\"'. Common causes are a missing custom metric or an unreachable scaling signal." \
    --arg e "The autoscaler should report status ACTIVE." \
    --arg a "The autoscaler reports status $autoscaler_status." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

if [ "$autoscaler_present" = "true" ]; then
  # A group pinned at its max that is still under target size (or has heavy
  # current actions) indicates it cannot scale to meet demand.
  if [ "$target_size" -ge "$max_size" ] && [ "$max_size" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Instance group \`$INSTANCE_GROUP_NAME\` cannot scale to meet demand" \
      --arg d "Managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` is operating at its autoscaler maximum ($max_size replicas) while there is still outstanding demand (target size $target_size). The group may be unable to scale to absorb load." \
      --arg s "4" \
      --arg ns "Assess whether the autoscaler max is too low for current demand. Increase '--max-num-replicas' on the autoscaler or investigate scheduler/unschedulable events in the instances." \
      --arg e "The group should be able to scale to meet demand within its autoscaler bounds." \
      --arg a "The group is at its autoscaler maximum of $max_size replicas with target size $target_size." \
      '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
               "next_steps": $ns, "expected": $e, "actual": $a}]')
  fi

  # Autoscaler configured but target size frozen at 0 while min is > 0.
  if [ "$target_size" -le 0 ] && [ "$min_size" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Instance group \`$INSTANCE_GROUP_NAME\` autoscaler target is below minimum" \
      --arg d "Managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has target size $target_size, below the autoscaler minimum ($min_size). The autoscaler may have failed to scale the group up." \
      --arg s "3" \
      --arg ns "Investigate autoscaler operation: 'gcloud compute instance-groups managed set-autoscaling' or review Cloud Monitoring autoscaling metrics for capacity scaling failures." \
      --arg e "Target size should be within autoscaler min/max bounds." \
      --arg a "Target size $target_size is below autoscaler minimum $min_size." \
      '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
               "next_steps": $ns, "expected": $e, "actual": $a}]')
  fi
fi

# A managed group with no autoscaler and a target size of zero holds no capacity
# at all. The autoscaled case is already covered above against the autoscaler
# minimum, so only the un-autoscaled group is reported here.
if [ "$autoscaler_present" = "false" ] && [ "$target_size" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Managed instance group \`$INSTANCE_GROUP_NAME\` has target size 0" \
    --arg d "Managed instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has a target size of 0 and no autoscaler. This can indicate intentional scale-to-zero or a misconfiguration that leaves the group without capacity." \
    --arg s "2" \
    --arg ns "Review the group target size: 'gcloud compute instance-groups managed describe $INSTANCE_GROUP_NAME $LOCATION_FLAG=$LOCATION --project=$GCP_PROJECT_ID'. Confirm scale-to-zero is intentional, or resize the group / attach an autoscaler." \
    --arg e "The managed group should have a non-zero target size, or an autoscaler that can scale it up on demand." \
    --arg a "The managed group has a target size of 0 and no autoscaler." \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
             "next_steps": $ns, "expected": $e, "actual": $a}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Autoscaling check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Managed group summary:"
echo "$desc" | jq '{name, targetSize, state, currentActions}'
