#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="storage_utilization_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
STORAGE_UTILIZATION_THRESHOLD_GB="${STORAGE_UTILIZATION_THRESHOLD_GB:-50}"
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

summary_json='[]'
repo_count="$(echo "$repos_json" | jq 'length')"
idx=0

while [[ "$idx" -lt "$repo_count" ]]; do
  repo_name="$(echo "$repos_json" | jq -r ".[$idx].name")"
  repo_location="$(echo "$repos_json" | jq -r ".[$idx].location")"
  repo_format="$(echo "$repos_json" | jq -r ".[$idx].format")"
  repository_path="$(echo "$repos_json" | jq -r ".[$idx].repository_path")"
  repo_size_bytes="$(echo "$repos_json" | jq -r ".[$idx].size_bytes // 0")"

  image_count=0
  tag_count=0
  sampled_bytes=0

  if repository_is_docker_format "$repo_format"; then
    images_json="$(list_docker_images "$repository_path")"
    image_count="$(echo "$images_json" | jq 'length')"
    tag_count="$(echo "$images_json" | jq '[.[] | (.tags // []) | length] | add // 0')"
    sampled_bytes="$(echo "$images_json" | jq '[.[] | (.metadata.imageSizeBytes // "0" | tonumber)] | add // 0')"
  fi

  estimated_bytes="$repo_size_bytes"
  if [[ "$sampled_bytes" -gt "$estimated_bytes" ]]; then
    estimated_bytes="$sampled_bytes"
  fi
  estimated_gb="$(bytes_to_gb "$estimated_bytes")"

  summary_json="$(echo "$summary_json" | jq \
    --arg project "$GCP_PROJECT_ID" \
    --arg location "$repo_location" \
    --arg name "$repo_name" \
    --arg format "$repo_format" \
    --argjson image_count "$image_count" \
    --argjson tag_count "$tag_count" \
    --arg estimated_gb "$estimated_gb" \
    '. += [{
      project: $project,
      location: $location,
      repository: $name,
      format: $format,
      image_count: $image_count,
      tag_count: $tag_count,
      estimated_storage_gb: ($estimated_gb | tonumber)
    }]')"

  threshold_gb="$(echo "$STORAGE_UTILIZATION_THRESHOLD_GB" | awk '{print ($1 == "" ? 0 : $1)}')"
  if [[ "$(awk -v a="$estimated_gb" -v b="$threshold_gb" 'BEGIN { print (b > 0 && a > b) ? 1 : 0 }')" -eq 1 ]]; then
    add_issue \
      "Artifact Registry repository \`${repo_location}/${repo_name}\` exceeds storage utilization threshold" \
      3 \
      "Repository estimated storage should remain below ${STORAGE_UTILIZATION_THRESHOLD_GB} GB when threshold is enabled" \
      "Estimated storage ${estimated_gb} GB exceeds threshold ${STORAGE_UTILIZATION_THRESHOLD_GB} GB" \
      "Images=${image_count}, tags=${tag_count}, format=${repo_format}. Repository metadata size_bytes=${repo_size_bytes}." \
      "Review stale/untagged images, apply cleanup policies, and delete unused image versions."
  fi

  echo "${repo_location}/${repo_name}: images=${image_count}, tags=${tag_count}, estimated_gb=${estimated_gb}" >&2
  idx=$((idx + 1))
done

echo "$summary_json" > storage_utilization_report.json
print_issues_json
echo "Storage utilization report saved to storage_utilization_report.json"
