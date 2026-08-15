#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Instance Group Member Health
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID
#   INSTANCE_GROUP_NAME  Name of the instance group to check (group scope)
#
# Checks that all member instances of the group are in RUNNING/healthy state,
# flagging stopped, degraded, or re-creating instances (e.g. nodes recycling in
# a managed group). Produces issues of severity 2/3.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${INSTANCE_GROUP_NAME:?Must set INSTANCE_GROUP_NAME}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="group_member_health_issues.json"
issues_json='[]'

# Start from a clean slate so a previous run's findings cannot leak into this
# one, and make any unexpected failure surface as an issue: an empty issue file
# would otherwise be read as "healthy".
echo '[]' > "$OUTPUT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Member Health Check Failed for \`$INSTANCE_GROUP_NAME\`" \
    --arg d "The member health check script exited with code $rc for instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Member state could not be assessed." \
    --arg ns "Re-run 'gcloud compute instance-groups list-instances $INSTANCE_GROUP_NAME --project=$GCP_PROJECT_ID' manually and confirm the service account has roles/compute.viewer." \
    --arg e "The member health check should complete and report the state of every group member." \
    --arg a "The member health check failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Member health check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking member health for instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID"

# Resolve the group location (zonal or regional). A bare --zones/--regions flag
# consumes the next argument and breaks the call, so the plain list command is
# used; it returns both zonal and regional groups. gcloud reports the location
# as a full URL, so only the trailing name is kept.
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
    --arg title "Cannot Locate Instance Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "Instance group \`$INSTANCE_GROUP_NAME\` could not be located in project \`$GCP_PROJECT_ID\`. It may not exist or may be in a different project." \
    --arg severity "3" \
    --arg next_steps "Verify the group name and project, then run 'gcloud compute instance-groups list' to confirm the group exists." \
    --arg expected "The instance group should exist and be locatable." \
    --arg actual "The instance group could not be located." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

instances=$(gcloud compute instance-groups list-instances "$INSTANCE_GROUP_NAME" \
  $LOCATION_FLAG "$LOCATION" --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")

if [ "$(echo "$instances" | jq length)" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Instance Group \`$INSTANCE_GROUP_NAME\` Has No Members" \
    --arg details "Instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has no member instances. An empty group cannot serve traffic or capacity." \
    --arg severity "3" \
    --arg next_steps "Investigate why the group has no members: check the instance template, autoscaler, and resize actions. For managed groups, review 'gcloud compute instance-groups managed get-autoscaling-policy'." \
    --arg expected "The instance group should have at least one running member instance." \
    --arg actual "The instance group has zero member instances." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Evaluate member statuses. Managed group instances carry a currentAction that
# indicates lifecycle (CREATING, RECREATING, DELETING, etc.); unmanaged members
# carry a STATUS of RUNNING/STOPPED/TERMINATED.
# The loop is fed by process substitution, not by a pipe: a pipe would run it in
# a subshell and every finding appended to issues_json would be discarded.
while read -r member; do
  instance_name=$(echo "$member" | jq -r '.instance' | sed 's#.*/##')
  status=$(echo "$member" | jq -r '.status // "UNKNOWN"')
  action=$(echo "$member" | jq -r '.currentAction // ""')
  instance_status=$(echo "$member" | jq -r '.instanceStatus // ""')

  echo "  Member $instance_name: status=$status action=$action"

  # Degraded / recycling members in a managed group.
  case "$action" in
    RECREATING|DELETING|ABANDONING|DELETING_WITHOUT_DELETE_INSTANCE)
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Member \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` is $action" \
        --arg d "Member instance \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` is being recycled (current action: $action). This reduces effective capacity and may indicate node churn." \
        --arg s "3" \
        --arg ns "Investigate why instances are recycling: review instance logs, the instance template, and any startup failures. Check 'gcloud compute operations list --filter=\"targetLink~$INSTANCE_GROUP_NAME\"'." \
        --arg e "All members should be running and stable with no recycling actions." \
        --arg a "Member \`$instance_name\` has current action $action." \
        --arg instance_name "$instance_name" \
        '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
                 "next_steps": $ns, "expected": $e, "actual": $a, "instance": $instance_name}]')
      ;;
  esac

  # Explicitly stopped or terminated members.
  if [ "$instance_status" = "STOPPING" ] || [ "$instance_status" = "TERMINATED" ] || [ "$status" = "STOPPED" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Member \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` is stopped/terminated" \
      --arg d "Member instance \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` is in state ($instance_status/$status) and is not serving traffic." \
      --arg s "2" \
      --arg ns "Start the instance and verify it rejoins the group: 'gcloud compute instances start $instance_name --project=$GCP_PROJECT_ID'. For managed groups, reconcile: 'gcloud compute instance-groups managed reconcile-instances'." \
      --arg e "All members should be in RUNNING state." \
      --arg a "Member \`$instance_name\` is in state $instance_status/$status." \
      --arg instance_name "$instance_name" \
      '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
               "next_steps": $ns, "expected": $e, "actual": $a, "instance": $instance_name}]')
  fi
done < <(echo "$instances" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_FILE"
echo "Member health check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Member summary:"
echo "$instances" | jq '[.[] | {instance: (.instance | split("/") | .[-1]), status, currentAction}]'
