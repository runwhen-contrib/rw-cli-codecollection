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

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME:-All}"

OUTPUT_FILE="group_summary_issues.json"
SUMMARY_FILE="group_health_summary.json"
issues_json='[]'

# Start from a clean slate. Appending to a file left behind by an earlier run
# would both duplicate findings and, once re-slurped by jq, produce a nested
# array that the runbook cannot iterate.
: > "$OUTPUT_FILE"
on_exit() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n \
    --arg t "Health Summary Generation Failed for \`$INSTANCE_GROUP_NAME\`" \
    --arg d "The health summary script exited with code $rc for project \`$GCP_PROJECT_ID\` (group filter: \`$INSTANCE_GROUP_NAME\`). No consolidated verdict could be produced." \
    --arg ns "Re-run the individual group checks and confirm each of them wrote its issue file." \
    --arg e "The summary script should aggregate every check result into one verdict." \
    --arg a "The summary script failed with exit code $rc." \
    '[{title: $t, details: $d, severity: 2, next_steps: $ns, expected: $e, actual: $a}]' \
    > "$OUTPUT_FILE"
}
trap on_exit EXIT

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

# The loop is fed by process substitution, not by a pipe: a pipe would run it in
# a subshell, so every tally below would be discarded and the summary would
# always report zero issues.
echo "[]" > /tmp/group_summary_agg.$$.json
while read -r group; do
  name=$(echo "$group" | jq -r '.name')

  group_issue_count=0
  group_info_count=0
  group_degraded="false"

  # Tally issues from each check file for this group.
  for key in "${!CHECK_FILES[@]}"; do
    file="${CHECK_FILES[$key]}"
    if [ -f "$file" ]; then
      # Only severities 1-3 mean the group is unhealthy. Severity 4 findings are
      # informational (for example, patch history that cannot be read because
      # OS Config is not in use) and must not make a healthy group look degraded,
      # which would also contradict the SLI score.
      count=$(jq '[.[] | select(.severity <= 3)] | length' "$file" 2>/dev/null || echo 0)
      info_count=$(jq '[.[] | select(.severity > 3)] | length' "$file" 2>/dev/null || echo 0)
      group_issue_count=$((group_issue_count + count))
      group_info_count=$((group_info_count + info_count))
      total_issues=$((total_issues + count))
      if [ "$count" -gt 0 ]; then
        group_degraded="true"
      fi
    fi
  done

  if [ "$group_degraded" = "true" ]; then
    overall_degraded=1
  fi

  echo "  Group $name: $group_issue_count issue(s), $group_info_count informational, degraded=$group_degraded"

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
    --argjson info_count "$group_info_count" \
    --argjson degraded "$([ "$group_degraded" = "true" ] && echo true || echo false)" \
    '{name: $name, project: $project, total_issues: $issue_count, informational: $info_count, degraded: $degraded}' \
    > "/tmp/summary_row.$$.json"
  jq -s '.[0] + [.[1]]' /tmp/group_summary_agg.$$.json "/tmp/summary_row.$$.json" > /tmp/group_summary_agg2.$$.json
  mv /tmp/group_summary_agg2.$$.json /tmp/group_summary_agg.$$.json
done < <(echo "$groups_json" | jq -c '.[]')

# Persist the aggregated summary, including the per-group rows collected above.
summary=$(jq -n \
  --arg project "$GCP_PROJECT_ID" \
  --arg filter "$INSTANCE_GROUP_NAME" \
  --argjson degraded "$overall_degraded" \
  --argjson total_issues "$total_issues" \
  --argjson groups "$(cat /tmp/group_summary_agg.$$.json)" \
  '{project: $project, group_filter: $filter, overall_degraded: $degraded, total_issues: $total_issues, groups: $groups}')
rm -f /tmp/group_summary_agg.$$.json /tmp/summary_row.$$.json

echo "$summary" > "$SUMMARY_FILE"

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Health summary generated. Overall degraded: $overall_degraded, total issues: $total_issues."
echo "Summary saved to $SUMMARY_FILE; $(jq length "$OUTPUT_FILE") degraded group verdict(s)."
echo "$summary" | jq .
