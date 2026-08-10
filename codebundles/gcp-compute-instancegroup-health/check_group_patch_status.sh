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

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"
PATCH_WARNING_DAYS="${PATCH_WARNING_DAYS:-30}"

OUTPUT_FILE="group_patch_issues.json"
issues_json='[]'

# Start from a clean slate so a previous run's findings cannot leak into this
# one, and make any unexpected failure surface as an issue: an empty issue file
# would otherwise be read as "healthy".
echo '[]' > "$OUTPUT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Patch Compliance Check Failed for \`$INSTANCE_GROUP_NAME\`" \
    --arg d "The OS patch compliance check script exited with code $rc for instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Patch state could not be assessed." \
    --arg ns "Re-run 'gcloud compute os-config patch-jobs list --project=$GCP_PROJECT_ID' manually and confirm the service account has roles/osconfig.viewer and roles/compute.viewer." \
    --arg e "The patch compliance check should complete and report the patch state of every group member." \
    --arg a "The patch compliance check failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

if [ "$INSTANCE_GROUP_NAME" = "All" ]; then
  echo "Patch compliance check requires a specific INSTANCE_GROUP_NAME. Skipping."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

echo "Checking OS patch compliance for instance group: $INSTANCE_GROUP_NAME in project: $GCP_PROJECT_ID (warning after $PATCH_WARNING_DAYS days)"

# Resolve group location and member instances.
# A bare --zones/--regions flag consumes the next argument and breaks the call,
# so the plain list command is used. The location comes back as a full URL.
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
patch_jobs_err=$(mktemp)
if ! patch_jobs=$(gcloud compute os-config patch-jobs list \
  --filter="state:(SUCCEEDED FAILED TIMED_OUT)" \
  --limit=10 --format=json --project="$GCP_PROJECT_ID" 2>"$patch_jobs_err"); then
  # OS Config may not be enabled on the project. Report that plainly instead of
  # silently treating it as "no patch problems".
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OS Config Patch History Unavailable for Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "Querying OS Config patch jobs failed in project \`$GCP_PROJECT_ID\`: $(head -c 400 "$patch_jobs_err"). Patch compliance for the members of group \`$INSTANCE_GROUP_NAME\` cannot be assessed." \
    --arg severity "4" \
    --arg next_steps "Enable the OS Config API ('gcloud services enable osconfig.googleapis.com --project=$GCP_PROJECT_ID') and grant the service account roles/osconfig.viewer." \
    --arg expected "OS Config patch job history should be queryable for the project." \
    --arg actual "The OS Config patch job query failed." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  rm -f "$patch_jobs_err"
  exit 0
fi
rm -f "$patch_jobs_err"

if [ "$(echo "$patch_jobs" | jq length)" -le 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No OS Patch History Found for Group \`$INSTANCE_GROUP_NAME\`" \
    --arg details "No recent OS Config patch jobs were found affecting instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\`. Without patch jobs, patch compliance cannot be verified for the group's members. This is reported as informational: it is a gap in coverage rather than evidence that the group is unhealthy." \
    --arg severity "4" \
    --arg next_steps "Enable OS Config on the member instances (roles/osconfig.serviceAgent) and schedule regular patch jobs via 'gcloud compute os-config patch-jobs execute' or Cloud Scheduler." \
    --arg expected "The group should have recent OS Config patch jobs confirming member instances are patched." \
    --arg actual "No OS Config patch jobs were found." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber),
             "next_steps": $next_steps, "expected": $expected, "actual": $actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Inspect each member's patch state from the latest matching patch job details.
cutoff_epoch=$(date -u -d "$PATCH_WARNING_DAYS days ago" +%s)

for job_id in $(echo "$patch_jobs" | jq -r '.[].name'); do
  # Only patch jobs older than PATCH_WARNING_DAYS count as "unremediated".
  job_created=$(echo "$patch_jobs" | jq -r --arg j "$job_id" 'first(.[] | select(.name == $j) | .createTime) // ""')
  if [ -n "$job_created" ]; then
    job_epoch=$(date -u -d "$job_created" +%s 2>/dev/null || echo 0)
    if [ "$job_epoch" -gt "$cutoff_epoch" ]; then
      echo "  Patch job $job_id is newer than $PATCH_WARNING_DAYS days; not treated as unremediated."
      continue
    fi
  fi

  job_details=$(gcloud compute os-config patch-jobs list-instance-details "$job_id" \
    --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")
  for instance in $members; do
    instance_name=$(echo "$instance" | sed 's#.*/##')
    patch_state=$(echo "$job_details" | jq -r --arg n "$instance_name" \
      '.[]? | select(.instance | contains($n)) | .state // ""' | head -1)
    if [ -z "$patch_state" ]; then
      continue
    fi
    echo "  Member $instance_name: patch state=$patch_state"
    # SUCCEEDED means the member is patched, so it is not a finding.
    if [ "$patch_state" = "FAILED" ] || [ "$patch_state" = "TIMED_OUT" ] || [ "$patch_state" = "NO_AGENT_DETECTED" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Member \`$instance_name\` of group \`$INSTANCE_GROUP_NAME\` has patch state $patch_state" \
        --arg d "Member instance \`$instance_name\` of instance group \`$INSTANCE_GROUP_NAME\` in project \`$GCP_PROJECT_ID\` has OS patch state \`$patch_state\` from patch job \`$job_id\`. The group may have members missing security patches for more than $PATCH_WARNING_DAYS days." \
        --arg s "3" \
        --arg ns "Remediate the member instance's patches: 'gcloud compute os-config patch-jobs execute --instance-filter-names=$instance_name'. Review the patch job details for the failing packages." \
        --arg e "All group members should have a SUCCEEDED patch state within the last $PATCH_WARNING_DAYS days." \
        --arg a "Member \`$instance_name\` has patch state $patch_state." \
        --arg instance_name "$instance_name" \
        '. += [{"title": $t, "details": $d, "severity": ($s | tonumber),
                 "next_steps": $ns, "expected": $e, "actual": $a, "instance": $instance_name}]')
    fi
  done
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Patch compliance check for $INSTANCE_GROUP_NAME complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
echo "Patch job history:"
echo "$patch_jobs" | jq '[.[] | {name, state, createTime}]'
