#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="cleanup_policy_recommendations_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.$(discovery_scope_key).json"
UNTAGGED_IMAGE_THRESHOLD_DAYS="${UNTAGGED_IMAGE_THRESHOLD_DAYS:-30}"
STALE_IMAGE_THRESHOLD_DAYS="${STALE_IMAGE_THRESHOLD_DAYS:-90}"
MIN_TAGS_TO_KEEP="${MIN_TAGS_TO_KEEP:-5}"
init_issues_file

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

gcp_configure_project

if [[ ! -f "$DISCOVERED_REPOSITORIES_FILE" ]]; then
  repos_json="$(discover_repositories "$GCP_PROJECT_ID" "$(location_filter)" "$(repository_filter)")"
  echo "$repos_json" > "$DISCOVERED_REPOSITORIES_FILE"
else
  repos_json="$(cat "$DISCOVERED_REPOSITORIES_FILE")"
fi

recommendations_json='[]'
untagged_seconds=$((UNTAGGED_IMAGE_THRESHOLD_DAYS * 86400))
stale_seconds=$((STALE_IMAGE_THRESHOLD_DAYS * 86400))

repo_count="$(echo "$repos_json" | jq 'length')"
idx=0
while [[ "$idx" -lt "$repo_count" ]]; do
  repo_name="$(echo "$repos_json" | jq -r ".[$idx].name")"
  repo_location="$(echo "$repos_json" | jq -r ".[$idx].location")"
  repo_format="$(echo "$repos_json" | jq -r ".[$idx].format")"

  if ! repository_is_docker_format "$repo_format"; then
    idx=$((idx + 1))
    continue
  fi

  # Only recommend a policy where one is actually missing. Recommending (and
  # raising an issue) for a repository that already has full cleanup coverage
  # contradicts check-cleanup-policies.sh, which finds nothing wrong with it.
  gaps="$(repository_cleanup_policy_gaps "$repo_name" "$repo_location")"
  if [[ -z "$gaps" ]]; then
    echo "${repo_location}/${repo_name}: cleanup policies already cover untagged and aged artifacts; no recommendation." >&2
    idx=$((idx + 1))
    continue
  fi

  # A DELETE rule with olderThan=0s deletes everything the moment it is applied.
  # The thresholds are operator-tunable and legitimately set to 0 to make the
  # detection tasks flag every image, so refuse to turn that into a destructive
  # recommendation rather than emitting an apply_command that wipes the repo.
  delete_untagged_rule='{}'
  if [[ "$untagged_seconds" -gt 0 ]]; then
    delete_untagged_rule="$(jq -n --arg untagged "${untagged_seconds}s" \
      '{"delete-untagged": {action: "DELETE", condition: {tagState: "UNTAGGED", olderThan: $untagged}}}')"
  else
    echo "UNTAGGED_IMAGE_THRESHOLD_DAYS=0 -- omitting the delete-untagged rule from the recommendation (0s would delete every untagged manifest immediately)." >&2
  fi

  delete_stale_rule='{}'
  if [[ "$stale_seconds" -gt 0 ]]; then
    delete_stale_rule="$(jq -n --arg stale "${stale_seconds}s" \
      '{"delete-stale-tags": {action: "DELETE", condition: {tagState: "TAGGED", olderThan: $stale}}}')"
  else
    echo "STALE_IMAGE_THRESHOLD_DAYS=0 -- omitting the delete-stale-tags rule from the recommendation (0s would delete every tagged version immediately)." >&2
  fi

  suggested_policy="$(jq -n \
    --argjson untagged_rule "$delete_untagged_rule" \
    --argjson stale_rule "$delete_stale_rule" \
    --argjson keep "$MIN_TAGS_TO_KEEP" \
    '{
      cleanupPolicies: (
        $untagged_rule
        + {"keep-recent-tags": {action: "KEEP", mostRecentVersions: {keepCount: $keep}}}
        + $stale_rule
      )
    }')"

  recommendations_json="$(echo "$recommendations_json" | jq \
    --arg project "$GCP_PROJECT_ID" \
    --arg location "$repo_location" \
    --arg name "$repo_name" \
    --argjson policy "$suggested_policy" \
    '. += [{
      project: $project,
      location: $location,
      repository: $name,
      suggested_cleanup_policy: $policy,
      apply_command: ("gcloud artifacts repositories set-cleanup-policies " + $name + " --location=" + $location + " --project=" + $project + " --policy=POLICY_FILE.yaml")
    }]')"

  add_issue \
    "Suggested cleanup policy available for \`${repo_location}/${repo_name}\`" \
    4 \
    "Repositories should define automated cleanup aligned to retention requirements" \
    "Generated read-only cleanup policy recommendation for review" \
    "Gaps: ${gaps}. Suggested policy keeps ${MIN_TAGS_TO_KEEP} recent versions$(if [[ "$untagged_seconds" -gt 0 ]]; then echo ", deletes untagged manifests after ${UNTAGGED_IMAGE_THRESHOLD_DAYS} days"; fi)$(if [[ "$stale_seconds" -gt 0 ]]; then echo ", deletes tagged versions older than ${STALE_IMAGE_THRESHOLD_DAYS} days"; fi)." \
    "Review cleanup_policy_recommendations.json, validate in dry-run, then apply with elevated permissions if approved."

  idx=$((idx + 1))
done

echo "$recommendations_json" | jq '.' > cleanup_policy_recommendations.json
print_issues_summary
