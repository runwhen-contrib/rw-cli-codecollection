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
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="group_autoscaling_issues.json"
issues_json='[]'

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Autoscaling check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking autoscaling and capacity for managed instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID"

# Resolve location of the managed group.
zone=$(gcloud compute instance-groups managed list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(zone)" --project="$GCP_PROJECT_ID" 2>/dev/null | head -1)
region=$(gcloud compute instance-groups managed list --filter="name=$INSTANCE_GROUP_NAME" \
  --format="value(region)" --project="$GCP_PROJECT_ID" 2>/dev/null | head -1)

if [ -n "$zone" ] && [ "$zone" != "null" ] && [ -n "$zone" ]; then
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
current_actions=$(echo "$desc" | jq '{creating: .currentActions.creating // 0, deleting: .currentActions.deleting // 0, recreating: .currentActions.recreating // 0, none: .currentActions.none // 0}')
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

# Fetch and evaluate the autoscaling policy.
policy=$(gcloud compute instance-groups managed get-autoscaling-policy "$INSTANCE_GROUP_NAME" \
  $LOCATION_FLAG "$LOCATION" --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "{}")

has_policy=$(echo "$policy" | jq 'if type == "array" then length else (has("autoscalingPolicy") or type == "object") end' 2>/dev/null || echo "0")
echo "  Autoscaling policy present: $has_policy"

if [ "$has_policy" != "0" ] && [ "$(echo "$policy" | jq 'if type=="array" then length else 1 end')" -gt 0 ]; then
  min_size=$(echo "$policy" | jq -r 'if type=="array" then .[0].autoscalingPolicy.minNumReplicas else .minNumReplicas end // 0')
  max_size=$(echo "$policy" | jq -r 'if type=="array" then .[0].autoscalingPolicy.maxNumReplicas else .maxNumReplicas end // 0')
  echo "  Autoscaler bounds: min=$min_size max=$max_size"

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

echo "$issues_json" > "$OUTPUT_FILE"
echo "Autoscaling check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Managed group summary:"
echo "$desc" | jq '{name, targetSize, state, currentActions}'
