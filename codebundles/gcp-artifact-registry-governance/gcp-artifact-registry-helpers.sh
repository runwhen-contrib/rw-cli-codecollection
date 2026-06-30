#!/usr/bin/env bash
# Shared helpers for GCP Artifact Registry governance scripts.

set -euo pipefail

ISSUES_FILE="${ISSUES_FILE:-issues.json}"
DISCOVERED_REPOSITORIES_FILE="${DISCOVERED_REPOSITORIES_FILE:-discovered_repositories.json}"
IMAGE_LIST_MAX="${IMAGE_LIST_MAX:-500}"

init_issues_file() {
  echo '[]' > "$ISSUES_FILE"
}

init_discovered_repositories_file() {
  echo '[]' > "$DISCOVERED_REPOSITORIES_FILE"
}

add_issue() {
  local title="$1"
  local severity="$2"
  local expected="$3"
  local actual="$4"
  local details="$5"
  local next_steps="$6"
  local reproduce_hint="${7:-}"

  jq -n \
    --arg title "$title" \
    --argjson severity "$severity" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg details "$details" \
    --arg next_steps "$next_steps" \
    --arg reproduce_hint "$reproduce_hint" \
    '{
      title: $title,
      severity: $severity,
      expected: $expected,
      actual: $actual,
      details: $details,
      next_steps: $next_steps,
      reproduce_hint: $reproduce_hint
    }' | jq -s ".[0] as \$i | $(cat "$ISSUES_FILE") + [\$i]" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    add_issue \
      "Missing required environment variable \`${name}\`" \
      4 \
      "Required environment variables should be set before running governance checks" \
      "Environment variable \`${name}\` is not set" \
      "Set \`${name}\` in the CodeBundle configuration or taskset template." \
      "Export \`${name}\` and rerun the task."
    return 1
  fi
  return 0
}

gcp_activate() {
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" >/dev/null 2>&1 || {
      add_issue \
        "Failed to authenticate to GCP with service account credentials" \
        4 \
        "Valid GCP credentials should authenticate successfully" \
        "gcloud auth activate-service-account failed" \
        "Verify the \`gcp_credentials\` secret contains a valid service account JSON with Artifact Registry read access." \
        "Confirm the service account key is valid and has roles/artifactregistry.reader."
      return 1
    }
  fi

  if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
    gcloud config set project "${GCP_PROJECT_ID}" >/dev/null 2>&1 || true
  fi
  return 0
}

normalize_csv_or_all() {
  local value="${1:-All}"
  value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"
  if [[ "$value" == "all" || -z "$value" ]]; then
    echo "ALL"
  else
    echo "$value"
  fi
}

location_filter() {
  local locations_setting
  locations_setting="$(normalize_csv_or_all "${ARTIFACT_REGISTRY_LOCATIONS:-All}")"
  if [[ -n "${ARTIFACT_REGISTRY_LOCATION:-}" && "${ARTIFACT_REGISTRY_LOCATION}" != "All" ]]; then
    echo "${ARTIFACT_REGISTRY_LOCATION}"
    return
  fi
  echo "$locations_setting"
}

repository_filter() {
  local repos_setting
  repos_setting="$(normalize_csv_or_all "${ARTIFACT_REGISTRY_REPOSITORIES:-All}")"
  if [[ -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" && "${ARTIFACT_REGISTRY_REPOSITORY}" != "All" ]]; then
    echo "${ARTIFACT_REGISTRY_REPOSITORY}"
    return
  fi
  echo "$repos_setting"
}

list_artifact_registry_locations() {
  local project_id="$1"
  local filter="$2"
  if [[ "$filter" == "ALL" ]]; then
    gcloud artifacts locations list --project="$project_id" --format='value(locationId)' 2>/dev/null || true
  else
    echo "$filter" | tr ',' '\n' | sed '/^$/d'
  fi
}

repository_matches_filter() {
  local repo_name="$1"
  local repo_filter="$2"
  if [[ "$repo_filter" == "ALL" ]]; then
    return 0
  fi
  local candidate
  IFS=',' read -ra candidates <<< "$repo_filter"
  for candidate in "${candidates[@]}"; do
    candidate="$(echo "$candidate" | xargs)"
    if [[ "$candidate" == "$repo_name" ]]; then
      return 0
    fi
  done
  return 1
}

discover_repositories() {
  local project_id="$1"
  local location_filter_value="$2"
  local repository_filter_value="$3"
  local repos_json='[]'
  local location

  while IFS= read -r location; do
    [[ -z "$location" ]] && continue
    local list_json
    if ! list_json="$(gcloud artifacts repositories list \
      --project="$project_id" \
      --location="$location" \
      --format=json 2>"${location}.err.log")"; then
      local err_msg
      err_msg="$(cat "${location}.err.log" 2>/dev/null || echo "Unknown error")"
      add_issue \
        "Cannot list Artifact Registry repositories in location \`${location}\` for project \`${project_id}\`" \
        3 \
        "Artifact Registry repositories should be listable with reader permissions" \
        "gcloud artifacts repositories list failed for location \`${location}\`" \
        "$err_msg" \
        "Verify roles/artifactregistry.reader on project \`${project_id}\` and that artifactregistry.googleapis.com is enabled."
      continue
    fi

    local repo_count
    repo_count="$(echo "$list_json" | jq 'length')"
    local idx=0
    while [[ "$idx" -lt "$repo_count" ]]; do
      local repo_name repo_format repo_mode size_bytes repository_path
      repo_name="$(echo "$list_json" | jq -r ".[$idx].name | split(\"/\") | last")"
      repo_format="$(echo "$list_json" | jq -r ".[$idx].format // \"UNKNOWN\"")"
      repo_mode="$(echo "$list_json" | jq -r ".[$idx].mode // \"STANDARD_REPOSITORY\"")"
      size_bytes="$(echo "$list_json" | jq -r ".[$idx].sizeBytes // \"0\"")"
      repository_path="${location}-docker.pkg.dev/${project_id}/${repo_name}"

      if repository_matches_filter "$repo_name" "$repository_filter_value"; then
        repos_json="$(echo "$repos_json" | jq \
          --arg project "$project_id" \
          --arg location "$location" \
          --arg name "$repo_name" \
          --arg format "$repo_format" \
          --arg mode "$repo_mode" \
          --arg size_bytes "$size_bytes" \
          --arg repository_path "$repository_path" \
          '. += [{
            project: $project,
            location: $location,
            name: $name,
            format: $format,
            mode: $mode,
            size_bytes: ($size_bytes | tonumber? // 0),
            repository_path: $repository_path
          }]')"
      fi
      idx=$((idx + 1))
    done
  done < <(list_artifact_registry_locations "$project_id" "$location_filter_value")

  echo "$repos_json"
}

repository_is_docker_format() {
  local format="$1"
  [[ "$format" == "DOCKER" || "$format" == "docker" ]]
}

list_docker_images() {
  local repository_path="$1"
  gcloud artifacts docker images list "$repository_path" \
    --include-tags \
    --limit="$IMAGE_LIST_MAX" \
    --format=json 2>/dev/null || echo '[]'
}

bytes_to_gb() {
  awk -v bytes="${1:-0}" 'BEGIN { if (bytes <= 0) print "0.00"; else printf "%.2f", bytes / (1024^3) }'
}

days_since_timestamp() {
  local ts="$1"
  local now epoch then_epoch
  now="$(date -u +%s)"
  then_epoch="$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null || echo "$now")"
  echo $(( (now - then_epoch) / 86400 ))
}

print_issues_json() {
  cat "$ISSUES_FILE"
}
