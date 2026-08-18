#!/usr/bin/env bash
# Shared helpers for GCP Artifact Registry governance scripts.

set -euo pipefail

ISSUES_FILE="${ISSUES_FILE:-issues.json}"
# The discovery cache is shared by the checks within one run, but the working
# directory (RUNWHEN_WORKDIR/cb-temp) persists between runs. Key the filename on
# the discovery scope so a run scoped to one repository can never reuse a
# project-wide list left behind by an earlier run.
discovery_scope_key() {
  printf '%s|%s|%s' "${GCP_PROJECT_ID:-}" "${ARTIFACT_REGISTRY_LOCATION:-}${ARTIFACT_REGISTRY_LOCATIONS:-}" \
    "${ARTIFACT_REGISTRY_REPOSITORY:-}${ARTIFACT_REGISTRY_REPOSITORIES:-}" | cksum | cut -d' ' -f1
}
DISCOVERED_REPOSITORIES_FILE="${DISCOVERED_REPOSITORIES_FILE:-discovered_repositories.$(discovery_scope_key).json}"
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

# Auth is established once, outside of task scripts: Suite Initialization runs
# `gcloud auth activate-service-account` against the credential that
# `secret_file__gcp_credentials` materializes inside the worker, and on the
# platform the secret import has already logged in before that. Task scripts must
# not re-run `gcloud auth` -- when the import already authenticated, the
# materialized value can be a status string rather than a key, so activating it
# fails and previously reported a bogus severity-4 credential issue on every
# platform run. A genuinely unauthenticated run still fails loudly:
# discover_repositories() raises an issue carrying the real gcloud stderr.
gcp_configure_project() {
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
    gcloud artifacts locations list --project="$project_id" --format='value(name)' 2>/dev/null || true
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

# The platform only ever sees a task's stdout/stderr and its structured issues --
# never the files a script writes. Issues already reach it through ISSUES_FILE, so
# echoing the raw JSON array here just duplicated them as noise. Print a readable
# summary instead, which is the part a human reading Task Output actually wants.
print_issues_summary() {
  local count
  count="$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    echo "No issues raised."
  else
    echo "${count} issue(s) raised:"
    jq -r '.[] | "  - [sev \(.severity)] \(.title)"' "$ISSUES_FILE"
  fi
}

# Cleanup-policy gaps for one repository, as a space-separated list of tokens:
#   none      -- no cleanupPolicies at all
#   untagged  -- no rule covering UNTAGGED manifests
#   aged      -- no rule expiring aged tags
# Empty output means the repository is already covered. check-cleanup-policies.sh
# applies the same three tests to raise its sev-2/sev-3 findings; keep the two in
# step if either changes.
repository_cleanup_policy_gaps() {
  local repo_name="$1" repo_location="$2" describe_json gaps=""
  if ! describe_json="$(gcloud artifacts repositories describe "$repo_name" \
    --location="$repo_location" \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>/dev/null)"; then
    # Unreadable metadata is already reported by check-cleanup-policies.sh; treat
    # it as "cannot prove a gap" so we do not recommend a destructive policy blind.
    echo ""
    return 0
  fi

  local policies policy_count
  policies="$(echo "$describe_json" | jq '.cleanupPolicies // {}')"
  policy_count="$(echo "$policies" | jq 'length')"
  if [[ "$policy_count" -eq 0 ]]; then
    echo "none"
    return 0
  fi

  local has_untagged=false has_aged=false policy_name tag_state older_than
  for policy_name in $(echo "$policies" | jq -r 'keys[]'); do
    tag_state="$(echo "$policies" | jq -r --arg n "$policy_name" '.[$n].condition.tagState // empty')"
    older_than="$(echo "$policies" | jq -r --arg n "$policy_name" '.[$n].condition.olderThan // empty')"
    [[ "$tag_state" == "UNTAGGED" ]] && has_untagged=true
    [[ -n "$older_than" && "$tag_state" != "UNTAGGED" ]] && has_aged=true
  done

  [[ "$has_untagged" == "false" ]] && gaps="${gaps} untagged"
  [[ "$has_aged" == "false" ]] && gaps="${gaps} aged"
  echo "${gaps# }"
}
