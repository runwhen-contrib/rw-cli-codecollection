#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gcp-artifact-registry-helpers.sh
source "${SCRIPT_DIR}/gcp-artifact-registry-helpers.sh"

ISSUES_FILE="legacy_gcr_issues.json"
init_issues_file

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

if ! gcp_activate; then
  print_issues_json
  exit 0
fi

legacy_images=0
legacy_buckets=0
legacy_details=""

if gcr_images="$(gcloud container images list --repository="gcr.io/${GCP_PROJECT_ID}" --format='value(name)' 2>/dev/null)"; then
  if [[ -n "$gcr_images" ]]; then
    legacy_images="$(echo "$gcr_images" | sed '/^$/d' | wc -l | xargs)"
    legacy_details="${legacy_details}gcr.io/${GCP_PROJECT_ID} images: ${legacy_images}\n"
  fi
fi

for bucket in "artifacts.${GCP_PROJECT_ID}.appspot.com" "us.artifacts.${GCP_PROJECT_ID}.appspot.com" "eu.artifacts.${GCP_PROJECT_ID}.appspot.com" "asia.artifacts.${GCP_PROJECT_ID}.appspot.com"; do
  if gcloud storage ls "gs://${bucket}/" >/dev/null 2>&1; then
    object_count="$(gcloud storage ls -r "gs://${bucket}/**" 2>/dev/null | sed '/^$/d' | wc -l | xargs)"
    if [[ "${object_count:-0}" -gt 0 ]]; then
      legacy_buckets=$((legacy_buckets + 1))
      legacy_details="${legacy_details}Legacy bucket gs://${bucket} objects: ${object_count}\n"
    fi
  fi
done

repos_json="$(discover_repositories "$GCP_PROJECT_ID" "ALL" "ALL")"
artifact_repo_count="$(echo "$repos_json" | jq 'length')"

if [[ "$legacy_images" -gt 0 || "$legacy_buckets" -gt 0 ]]; then
  severity=3
  if [[ "$artifact_repo_count" -eq 0 ]]; then
    severity=2
  fi
  add_issue \
    "Legacy Container Registry (gcr.io) usage detected in project \`${GCP_PROJECT_ID}\`" \
    "$severity" \
    "Workloads should migrate from deprecated gcr.io to Artifact Registry" \
    "Found legacy GCR images/buckets while Artifact Registry repo count=${artifact_repo_count}" \
    "$(printf "%b" "$legacy_details")" \
    "Plan migration to Artifact Registry, update CI/CD image references, and retire legacy GCR buckets after cutover."
fi

if [[ "$artifact_repo_count" -eq 0 && "$legacy_images" -eq 0 && "$legacy_buckets" -eq 0 ]]; then
  add_issue \
    "No Artifact Registry repositories and no legacy GCR inventory in project \`${GCP_PROJECT_ID}\`" \
    4 \
    "Projects using container images should use Artifact Registry or show explicit legacy GCR inventory" \
    "Neither Artifact Registry repositories nor legacy gcr.io images were discovered" \
    "Verify artifactregistry.googleapis.com and containerregistry.googleapis.com are enabled and credentials include storage.objectViewer for legacy buckets." \
    "Confirm the project hosts container images or exclude it from governance scope."
fi

print_issues_json
echo "Legacy GCR usage analysis completed."
