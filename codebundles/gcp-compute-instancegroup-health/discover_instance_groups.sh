#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover GCP Compute Engine Instance Groups and Configurations
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID hosting the instance groups
#
# OPTIONAL ENV VARS:
#   INSTANCE_GROUP_NAME  If set to a specific group name, only that group is
#                        inspected; otherwise all groups in the project are.
#
# Lists managed and unmanaged instance groups, dumps group configuration
# (template, zones, target size, autoscaling settings), and identifies member
# instances. Reports configuration issues (severity 2/3).
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="instance_groups_issues.json"
REPORT_FILE="instance_groups_report.json"
issues_json='[]'

# Start from a clean slate so findings from a previous run (or a previous
# group) can never leak into this one, and make any unexpected failure surface
# as an issue: an empty issue file would otherwise be read as "healthy".
echo '[]' > "$OUTPUT_FILE"
echo '[]' > "$REPORT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Instance Group Discovery Failed in \`$GCP_PROJECT_ID\`" \
    --arg d "The instance group discovery script exited with code $rc in project \`$GCP_PROJECT_ID\`. Group inventory could not be collected, so group health cannot be assessed." \
    --arg ns "Re-run 'gcloud compute instance-groups list --project=$GCP_PROJECT_ID' manually and confirm the service account has roles/compute.viewer." \
    --arg e "The discovery script should complete and list the project's instance groups." \
    --arg a "The discovery script failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

echo "Discovering instance groups in project: $GCP_PROJECT_ID (group filter: $INSTANCE_GROUP_NAME)"

# -----------------------------------------------------------------------------
# Gather all instance groups (managed + unmanaged) across zones and regions.
# A bare --zones/--regions flag consumes the next argument, so the plain list
# command is used: it already returns both zonal and regional groups.
# -----------------------------------------------------------------------------
groups_raw=$(gcloud compute instance-groups list --format=json --project="$GCP_PROJECT_ID")
managed_spread=$(gcloud compute instance-groups managed list --format=json --project="$GCP_PROJECT_ID")

if [ "$(echo "$groups_raw" | jq length)" -le 0 ]; then
  echo "No instance groups found in project $GCP_PROJECT_ID."
  # A specific group was asked for and the project holds none, so say so
  # explicitly rather than reporting an empty, problem-free inventory.
  if [ "$INSTANCE_GROUP_NAME" != "All" ]; then
    jq -n \
      --arg title "Instance Group \`$INSTANCE_GROUP_NAME\` Not Found" \
      --arg details "Instance group \`$INSTANCE_GROUP_NAME\` was not found in project \`$GCP_PROJECT_ID\`: the project contains no instance groups at all." \
      --arg next_steps "Verify the project ID and the group name with 'gcloud compute instance-groups list --project=$GCP_PROJECT_ID'." \
      --arg expected "The instance group should exist in the project and be addressable by name." \
      --arg actual "The project contains no instance groups." \
      '[{title: $title, details: $details, severity: 3, next_steps: $next_steps, expected: $expected, actual: $actual}]' \
      > "$OUTPUT_FILE"
  fi
  exit 0
fi

# Normalise into a single JSON array, de-duplicated by name.
all_groups=$(echo "$groups_raw" | jq '[ .[] ] | group_by(.name) | map(.[0])')

# Filter to the requested group if a specific INSTANCE_GROUP_NAME was supplied.
if [ "$INSTANCE_GROUP_NAME" != "All" ]; then
  filtered=$(echo "$all_groups" | jq --arg n "$INSTANCE_GROUP_NAME" '[.[] | select(.name == $n)]')
  if [ "$(echo "$filtered" | jq length)" -le 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Instance Group \`$INSTANCE_GROUP_NAME\` Not Found" \
      --arg details "Instance group \`$INSTANCE_GROUP_NAME\` was not found in project \`$GCP_PROJECT_ID\`." \
      --arg severity "3" \
      --arg next_steps "Verify the instance group name and project. Run 'gcloud compute instance-groups list' to see available groups." \
      --arg expected "The instance group should exist in the project and be addressable by name." \
      --arg actual "No instance group named \`$INSTANCE_GROUP_NAME\` was found." \
      '. += [{
        "title": $title, "details": $details, "severity": ($severity | tonumber),
        "next_steps": $next_steps, "expected": $expected, "actual": $actual
      }]')
  else
    all_groups=$filtered
  fi
fi

echo "$all_groups" > "$REPORT_FILE"

# -----------------------------------------------------------------------------
# Dump per-group configuration details and identify members / target sizes.
# Findings collected above are carried into the file as JSON lines so they are
# not dropped by the per-group loop below.
# -----------------------------------------------------------------------------
echo "$issues_json" | jq -c '.[]' > "$OUTPUT_FILE"

echo "$all_groups" | jq -c '.[]' | while read -r group; do
  name=$(echo "$group" | jq -r '.name')
  location=$(echo "$group" | jq -r '.zone // .region // "unknown"')
  kind=$(echo "$group" | jq -r '.instanceGroup // "unmanaged"')

  echo "Inspecting group: $name (location: $location, kind: $kind)"

  # Determine whether this is a managed group (has a matching instanceGroupManager).
  # 'managed list' returns a plain JSON array, so index it as one.
  is_managed=$(echo "$managed_spread" | jq --arg n "$name" 'any(.[]?; .name == $n)')

  target_size=0
  if [ "$is_managed" = "true" ]; then
    location_flag="--zone"
    # Managed groups may be zonal or regional.
    region=$(echo "$managed_spread" | jq -r --arg n "$name" 'first(.[]? | select(.name == $n) | .region) // "" | sub(".*/"; "")')
    zone=$(echo "$managed_spread" | jq -r --arg n "$name" 'first(.[]? | select(.name == $n) | .zone) // "" | sub(".*/"; "")')
    if [ -n "$zone" ] && [ "$zone" != "null" ]; then
      location_flag="--zone"
      location=$zone
    elif [ -n "$region" ] && [ "$region" != "null" ]; then
      location_flag="--region"
      location=$region
    fi
    desc=$(gcloud compute instance-groups managed describe "$name" $location_flag "$location" --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "{}")
    target_size=$(echo "$desc" | jq -r '.targetSize // 0')
  else
    location_flag="--zone"
    if [ "$(echo "$group" | jq -r '.zone // ""')" = "" ]; then
      location_flag="--region"
    fi
  fi

  # Flag managed groups pinned to a target size of zero, which can indicate
  # capacity deliberately scaled to zero (or a misconfiguration).
  if [ "$is_managed" = "true" ] && [ "$target_size" -le 0 ]; then
    printf '{"title":"Managed instance group `%s` has target size 0","details":"Managed instance group `%s` in project `%s` has a target size of 0. This can indicate intentional scale-to-zero or a misconfiguration that leaves the group without capacity.","severity":2,"next_steps":"Review the group autoscaling policy and target size: gcloud compute instance-groups managed describe %s --zone=%s --project=%s. Confirm scale-to-zero is intentional or adjust the autoscaler min/max bounds.","expected":"The managed group should have a non-zero target size or an autoscaler that can scale it up on demand.","actual":"The managed group has a target size of 0.","group":"%s","issue_type":"zero_target_size"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$location" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

members=$(echo "$all_groups" | jq '[.[] | {name: .name, location: (.zone // .region)}]')
echo "Discovered $(echo "$all_groups" | jq length) instance group(s)."
echo "Groups and configurations saved to $REPORT_FILE; $(jq length "$OUTPUT_FILE") configuration issue(s)."
echo "Member instances summary:"
echo "$members" | jq .
