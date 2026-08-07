#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate Instance Group Health Summary
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID       GCP project ID
#
# OPTIONAL ENV VARS:
#   INSTANCE_GROUP_NAME  If set to a specific group, only that group is
#                        summarised; otherwise all groups are summarised.
#
# Aggregates all group-level check findings into a consolidated health summary
# per instance group (member health, autoscaling, patches, utilization) and an
# overall verdict. Emits issues of severity 2/3 for degraded groups.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="group_summary_issues.json"
SUMMARY_FILE="group_health_summary.json"
issues_json='[]'

echo "Generating instance group health summary for project: $GCP_PROJECT_ID (group filter: $INSTANCE_GROUP_NAME)"

# Gather the per-check issue files produced by the group-scoped tasks. These
# persist in the shared working directory for the current SLX's group.
declare -A CHECK_FILES=(
  ["member_health"]="group_member_health_issues.json"
  ["autoscaling"]="group_autoscaling_issues.json"
  ["patch"]="group_patch_issues.json"
  ["utilization"]="group_utilization_issues.json"
)

summary_rows=()
overall_degraded=0
total_issues=0

# Determine the set of groups to summarise. When a specific group was checked,
# we summarise that group; otherwise fall back to the discovery inventory.
if [ "$INSTANCE_GROUP_NAME" != "All" ]; then
  groups_json=$(jq -n --arg n "$INSTANCE_GROUP_NAME" '[{"name": $n}]')
else
  groups_json=$(cat instance_groups_report.json 2>/dev/null \
    | jq '[.[] | {name: .name, location: (.zone // .region)}]' \
    || echo "[]")
fi

echo "Building summary for $(echo "$groups_json" | jq length) group(s)."

echo "$groups_json" | jq -c '.[]' | while read -r group; do
  name=$(echo "$group" | jq -r '.name')

  group_issue_count=0
  group_degraded="false"
  > /tmp/group_summary_agg.$$.json
  echo "[]" > /tmp/group_summary_agg.$$.json

  # Tally issues from each check file for this group.
  for key in "${!CHECK_FILES[@]}"; do
    file="${CHECK_FILES[$key]}"
    if [ -f "$file" ]; then
      count=$(jq 'length' "$file" 2>/dev/null || echo 0)
      group_issue_count=$((group_issue_count + count))
      total_issues=$((total_issues + count))
      if [ "$count" -gt 0 ]; then
        group_degraded="true"
      fi
    fi
  done

  if [ "$group_degraded" = "true" ]; then
    overall_degraded=1
  fi

  echo "  Group $name: $group_issue_count issue(s), degraded=$group_degraded"

  if [ "$group_degraded" = "true" ]; then
    printf '{"title":"Instance group `%s` health is degraded","details":"Instance group `%s` in project `%s` has %s active issue(s) across member health, autoscaling, patch compliance, or utilization checks.","severity":3,"next_steps":"Review the individual check issues for this group and remediate the underlying cause. Re-run the group health checks to confirm resolution.","expected":"The instance group should have no active health issues.","actual":"The instance group has %s active health issue(s).","group":"%s"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$group_issue_count" "$group_issue_count" "$name" >> "$OUTPUT_FILE"
  else
    echo "  Group $name is healthy."
  fi

  # Append a summary row.
  jq -n \
    --arg name "$name" \
    --arg project "$GCP_PROJECT_ID" \
    --argjson issue_count "$group_issue_count" \
    --argjson degraded "$([ "$group_degraded" = "true" ] && echo true || echo false)" \
    '{name: $name, project: $project, total_issues: $issue_count, degraded: $degraded}' \
    > "/tmp/summary_row.$$.json"
  jq -s '.[0] + [.[1]]' /tmp/group_summary_agg.$$.json "/tmp/summary_row.$$.json" > /tmp/group_summary_agg2.$$.json
  mv /tmp/group_summary_agg2.$$.json /tmp/group_summary_agg.$$.json
done

# Persist the aggregated summary (only the last group's aggregate is retained
# from the subshell; see below for the authoritative aggregate).
summary=$(jq -n \
  --arg project "$GCP_PROJECT_ID" \
  --arg filter "$INSTANCE_GROUP_NAME" \
  --argjson degraded "$overall_degraded" \
  --argjson total_issues "$total_issues" \
  '{project: $project, group_filter: $filter, overall_degraded: $degraded, total_issues: $total_issues}')

echo "$summary" > "$SUMMARY_FILE"

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Health summary generated. Overall degraded: $overall_degraded, total issues: $total_issues."
echo "Summary saved to $SUMMARY_FILE; $(jq length "$OUTPUT_FILE") degraded group verdict(s)."
echo "$summary" | jq .
