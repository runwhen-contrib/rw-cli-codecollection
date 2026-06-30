#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="cleanup_policy_issues.json"
DISCOVERED_REPOSITORIES_FILE="discovered_repositories.json"
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

  if ! repository_is_docker_format "$repo_format"; then
    echo "Skipping non-Docker repository ${repo_location}/${repo_name} (format=${repo_format})" >&2
    idx=$((idx + 1))
    continue
  fi

  describe_json=""
  if ! describe_json="$(gcloud artifacts repositories describe "$repo_name" \
    --location="$repo_location" \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>"${repo_name}.describe.err"); then
    err_msg="$(cat "${repo_name}.describe.err" 2>/dev/null || echo "Unknown error")"
    add_issue \
      "Cannot describe Artifact Registry repository \`${repo_location}/${repo_name}\`" \
      3 \
      "Repository metadata should be readable for cleanup policy evaluation" \
      "gcloud artifacts repositories describe failed" \
      "$err_msg" \
      "Verify roles/artifactregistry.reader on project \`${GCP_PROJECT_ID}\`."
    idx=$((idx + 1))
    continue
  fi

  cleanup_policies="$(echo "$describe_json" | jq '.cleanupPolicies // {}')"
  policy_count="$(echo "$cleanup_policies" | jq 'length')"
  dry_run="$(echo "$describe_json" | jq -r '.cleanupPolicyDryRun // false')"

  if [[ "$policy_count" -eq 0 ]]; then
    add_issue \
      "Missing cleanup policy on Docker repository \`${repo_location}/${repo_name}\`" \
      2 \
      "Docker/OCI Artifact Registry repositories should define cleanup policies for untagged and aged artifacts" \
      "Repository has no cleanupPolicies configured" \
      "Project: ${GCP_PROJECT_ID}; repository: ${repo_location}/${repo_name}; format: ${repo_format}." \
      "Add cleanup policies that delete untagged manifests and aged tags. See https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy"
  else
    has_untagged_rule=false
    has_aged_tag_rule=false
    for policy_name in $(echo "$cleanup_policies" | jq -r 'keys[]'); do
      tag_state="$(echo "$cleanup_policies" | jq -r --arg n "$policy_name" '.[$n].condition.tagState // empty')"
      older_than="$(echo "$cleanup_policies" | jq -r --arg n "$policy_name" '.[$n].condition.olderThan // empty')"
      if [[ "$tag_state" == "UNTAGGED" ]]; then
        has_untagged_rule=true
      fi
      if [[ -n "$older_than" && "$tag_state" != "UNTAGGED" ]]; then
        has_aged_tag_rule=true
      fi
    done

    if [[ "$has_untagged_rule" == "false" ]]; then
      add_issue \
        "Cleanup policy missing untagged manifest rule for \`${repo_location}/${repo_name}\`" \
        3 \
        "Cleanup policies should include a rule covering UNTAGGED manifests" \
        "No cleanup policy with condition.tagState=UNTAGGED was found" \
        "Configured policies: $(echo "$cleanup_policies" | jq -c 'keys')" \
        "Add a delete-untagged cleanup policy rule to control dangling manifest storage growth."
    fi

    if [[ "$has_aged_tag_rule" == "false" ]]; then
      add_issue \
        "Cleanup policy missing aged tag rule for \`${repo_location}/${repo_name}\`" \
        3 \
        "Cleanup policies should expire aged tags to limit storage spend" \
        "No cleanup policy with condition.olderThan was found for tagged artifacts" \
        "Configured policies: $(echo "$cleanup_policies" | jq -c 'keys')" \
        "Add a keep-most-recent or delete-old-tags cleanup policy based on your retention requirements."
    fi

    if [[ "$dry_run" == "true" ]]; then
      add_issue \
        "Cleanup policy dry-run enabled for \`${repo_location}/${repo_name}\`" \
        4 \
        "Production repositories should apply cleanup policies, not dry-run only" \
        "cleanupPolicyDryRun=true on repository" \
        "Project: ${GCP_PROJECT_ID}; repository: ${repo_location}/${repo_name}." \
        "Disable dry-run after validating recommended cleanup rules."
    fi
  fi

  idx=$((idx + 1))
done

print_issues_json
echo "Cleanup policy analysis completed."
