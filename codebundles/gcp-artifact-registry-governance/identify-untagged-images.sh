#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="untagged_images_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
UNTAGGED_IMAGE_THRESHOLD_DAYS="${UNTAGGED_IMAGE_THRESHOLD_DAYS:-30}"
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

repo_count="$(echo "$repos_json" | jq 'length')"
idx=0
while [[ "$idx" -lt "$repo_count" ]]; do
  repo_name="$(echo "$repos_json" | jq -r ".[$idx].name")"
  repo_location="$(echo "$repos_json" | jq -r ".[$idx].location")"
  repo_format="$(echo "$repos_json" | jq -r ".[$idx].format")"
  repository_path="$(echo "$repos_json" | jq -r ".[$idx].repository_path")"

  if ! repository_is_docker_format "$repo_format"; then
    idx=$((idx + 1))
    continue
  fi

  images_json="$(list_docker_images "$repository_path")"
  image_count="$(echo "$images_json" | jq 'length')"
  untagged_count=0
  untagged_bytes=0
  image_idx=0

  while [[ "$image_idx" -lt "$image_count" ]]; do
    tags="$(echo "$images_json" | jq -r ".[$image_idx].tags // [] | length")"
    update_time="$(echo "$images_json" | jq -r ".[$image_idx].updateTime // .[$image_idx].uploadTime // .[$image_idx].createTime // empty")"
    image_size="$(echo "$images_json" | jq -r ".[$image_idx].metadata.imageSizeBytes // \"0\"")"

    if [[ "$tags" -eq 0 ]]; then
      age_days=0
      if [[ -n "$update_time" ]]; then
        age_days="$(days_since_timestamp "$update_time")"
      fi
      if [[ "$age_days" -ge "$UNTAGGED_IMAGE_THRESHOLD_DAYS" ]]; then
        untagged_count=$((untagged_count + 1))
        untagged_bytes=$((untagged_bytes + image_size))
      fi
    fi
    image_idx=$((image_idx + 1))
  done

  if [[ "$untagged_count" -gt 0 ]]; then
    add_issue \
      "Untagged manifests consuming storage in \`${repo_location}/${repo_name}\`" \
      3 \
      "Untagged or dangling manifests older than ${UNTAGGED_IMAGE_THRESHOLD_DAYS} days should be cleaned up" \
      "Found ${untagged_count} untagged manifests (~$(bytes_to_gb "$untagged_bytes") GB sampled)" \
      "Repository ${repository_path}; untagged_count=${untagged_count}; threshold_days=${UNTAGGED_IMAGE_THRESHOLD_DAYS}." \
      "Enable a delete-untagged cleanup policy and consider keep-minimum-versions rules for tagged releases."
  fi

  idx=$((idx + 1))
done

print_issues_json
echo "Untagged image analysis completed (threshold=${UNTAGGED_IMAGE_THRESHOLD_DAYS} days)."
