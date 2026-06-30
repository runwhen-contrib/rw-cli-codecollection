#!/usr/bin/env bash
set -euo pipefail
set -x

# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL:
#   ARTIFACT_REGISTRY_LOCATIONS (default All)
#   ARTIFACT_REGISTRY_REPOSITORIES (default All)
#   ARTIFACT_REGISTRY_LOCATION
#   ARTIFACT_REGISTRY_REPOSITORY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="discover_repositories_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
init_issues_file
init_discovered_repositories_file

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

if ! require_env GCP_PROJECT_ID; then
  print_issues_json
  exit 0
fi

if ! gcp_activate; then
  print_issues_json
  exit 0
fi

location_filter_value="$(location_filter)"
repository_filter_value="$(repository_filter)"

echo "Discovering Artifact Registry repositories in project ${GCP_PROJECT_ID}" >&2
echo "Location filter: ${location_filter_value}" >&2
echo "Repository filter: ${repository_filter_value}" >&2

repos_json="$(discover_repositories "$GCP_PROJECT_ID" "$location_filter_value" "$repository_filter_value")"
echo "$repos_json" > "$DISCOVERED_REPOSITORIES_FILE"

repo_count="$(echo "$repos_json" | jq 'length')"
if [[ "$repo_count" -eq 0 ]]; then
  add_issue \
    "No Artifact Registry repositories discovered in project \`${GCP_PROJECT_ID}\`" \
    4 \
    "At least one Artifact Registry repository should exist when governance checks are configured" \
    "Discovery returned zero repositories for the configured location/repository filters" \
    "Locations filter: ${location_filter_value}; repositories filter: ${repository_filter_value}. Confirm repositories exist or adjust filters." \
    "Create an Artifact Registry repository or update ARTIFACT_REGISTRY_LOCATIONS / ARTIFACT_REGISTRY_REPOSITORIES."
else
  echo "Discovered ${repo_count} repository/repositories." >&2
  echo "$repos_json" | jq -r '.[] | "- \(.location)/\(.name) (\(.format), size_bytes=\(.size_bytes))"' >&2
fi

print_issues_json
echo "Discovery completed. Results saved to ${DISCOVERED_REPOSITORIES_FILE}"
