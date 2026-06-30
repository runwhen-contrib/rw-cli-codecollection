#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="cleanup_policy_recommendations_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
UNTAGGED_IMAGE_THRESHOLD_DAYS="${UNTAGGED_IMAGE_THRESHOLD_DAYS:-30}"
STALE_IMAGE_THRESHOLD_DAYS="${STALE_IMAGE_THRESHOLD_DAYS:-90}"
MIN_TAGS_TO_KEEP="${MIN_TAGS_TO_KEEP:-5}"
init_issues_file

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

if ! gcp_activate; then
  print_issues_json
  exit 0
fi

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

  suggested_policy="$(jq -n \
    --arg untagged "${untagged_seconds}s" \
    --arg stale "${stale_seconds}s" \
    --argjson keep "$MIN_TAGS_TO_KEEP" \
    '{
      cleanupPolicies: {
        "delete-untagged": {
          action: "DELETE",
          condition: {
            tagState: "UNTAGGED",
            olderThan: $untagged
          }
        },
        "keep-recent-tags": {
          action: "KEEP",
          mostRecentVersions: {
            keepCount: $keep
          }
        },
        "delete-stale-tags": {
          action: "DELETE",
          condition: {
            tagState: "TAGGED",
            olderThan: $stale
          }
        }
      }
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
    "Suggested policy keeps ${MIN_TAGS_TO_KEEP} recent versions, deletes untagged manifests after ${UNTAGGED_IMAGE_THRESHOLD_DAYS} days, and deletes tagged versions older than ${STALE_IMAGE_THRESHOLD_DAYS} days." \
    "Review cleanup_policy_recommendations.json, validate in dry-run, then apply with elevated permissions if approved."

  idx=$((idx + 1))
done

echo "$recommendations_json" | jq '.' > cleanup_policy_recommendations.json
print_issues_json
echo "Cleanup policy recommendations saved to cleanup_policy_recommendations.json"
