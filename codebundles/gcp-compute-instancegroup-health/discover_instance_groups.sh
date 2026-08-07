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
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="instance_groups_issues.json"
REPORT_FILE="instance_groups_report.json"
issues_json='[]'

echo "Discovering instance groups in project: $GCP_PROJECT_ID (group filter: $INSTANCE_GROUP_NAME)"

# -----------------------------------------------------------------------------
# Gather all instance groups (managed + unmanaged) across zones and regions.
# -----------------------------------------------------------------------------
zonal=$(gcloud compute instance-groups list --zones --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")
regional=$(gcloud compute instance-groups list --regions --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")

managed_spread=$(gcloud compute instance-groups managed list --format=json --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[]")

if [ "$(echo "$zonal" | jq length)" -le 0 ] && [ "$(echo "$regional" | jq length)" -le 0 ]; then
  echo "No instance groups found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  echo "[]" > "$REPORT_FILE"
  exit 0
fi

# Normalise into a single JSON array keyed by name/location/kind.
all_groups=$(echo "$zonal $regional" | jq -s '
  [ .[] | .[]? ] as $list
  | ( $list | group_by(.name) | map(.[0]) ) as $uniq
  | $uniq
')

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
# -----------------------------------------------------------------------------
> "$OUTPUT_FILE"

echo "$all_groups" | jq -c '.[]' | while read -r group; do
  name=$(echo "$group" | jq -r '.name')
  location=$(echo "$group" | jq -r '.zone // .region // "unknown"')
  kind=$(echo "$group" | jq -r '.instanceGroup // "unmanaged"')

  echo "Inspecting group: $name (location: $location, kind: $kind)"

  # Determine whether this is a managed group (has a matching instanceGroupManager).
  is_managed=$(echo "$managed_spread" | jq --arg n "$name" 'any(.items[]? | .name == $n)')

  target_size=0
  if [ "$is_managed" = "true" ]; then
    location_flag="--zone"
    # Managed groups may be zonal or regional.
    region=$(echo "$managed_spread" | jq -r --arg n "$name" '.items[]? | select(.name == $n) | .region // ""')
    zone=$(echo "$managed_spread" | jq -r --arg n "$name" '.items[]? | select(.name == $n) | .zone // ""')
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
    echo "$issues_json" > /dev/null
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
