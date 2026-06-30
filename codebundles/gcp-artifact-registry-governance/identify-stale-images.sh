#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="stale_images_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
STALE_IMAGE_THRESHOLD_DAYS="${STALE_IMAGE_THRESHOLD_DAYS:-90}"
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
  stale_count=0
  stale_bytes=0
  image_idx=0

  while [[ "$image_idx" -lt "$image_count" ]]; do
    update_time="$(echo "$images_json" | jq -r ".[$image_idx].updateTime // .[$image_idx].uploadTime // .[$image_idx].createTime // empty")"
    tags="$(echo "$images_json" | jq -r ".[$image_idx].tags // [] | join(\",\")")"
    image_size="$(echo "$images_json" | jq -r ".[$image_idx].metadata.imageSizeBytes // \"0\"")"

    if [[ -z "$update_time" ]]; then
      image_idx=$((image_idx + 1))
      continue
    fi

    age_days="$(days_since_timestamp "$update_time")"
    if [[ "$age_days" -ge "$STALE_IMAGE_THRESHOLD_DAYS" && -n "$tags" ]]; then
      stale_count=$((stale_count + 1))
      stale_bytes=$((stale_bytes + image_size))
    fi
    image_idx=$((image_idx + 1))
  done

  if [[ "$stale_count" -gt 0 ]]; then
    severity=3
    if [[ "$stale_count" -ge 25 ]]; then
      severity=2
    fi
    add_issue \
      "Stale container images in \`${repo_location}/${repo_name}\`" \
      "$severity" \
      "Tagged images should be pulled or updated within ${STALE_IMAGE_THRESHOLD_DAYS} days" \
      "Found ${stale_count} tagged image versions older than ${STALE_IMAGE_THRESHOLD_DAYS} days (~$(bytes_to_gb "$stale_bytes") GB sampled)" \
      "Repository ${repository_path}; stale_count=${stale_count}; threshold_days=${STALE_IMAGE_THRESHOLD_DAYS}. Last-pull timestamps may be unavailable; updateTime/uploadTime used as fallback." \
      "Review stale tags for deletion, add cleanup policies, or confirm images are still required."
  fi

  idx=$((idx + 1))
done

print_issues_json
echo "Stale image analysis completed (threshold=${STALE_IMAGE_THRESHOLD_DAYS} days)."
