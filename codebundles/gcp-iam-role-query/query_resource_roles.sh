#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that provides the IAM context.
#   RESOURCE_NAME    - Full (projects/x/...) or short name of the resource.
#   SERVICE_TYPE     - GCP service type used to scope the query (optional).
#
# Returns the IAM policy and role bindings for a user-supplied GCP resource.
# Resource names may be fully-qualified (projects/x/zones/y/...) or short forms
# (bucket-name, cluster-name). Failures to resolve the resource are reported as
# informational (severity 1) issues; the policy itself is printed to stdout.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="resource_role_issues.json"
issues_json='[]'

echo "Querying IAM roles for resource: ${RESOURCE_NAME:-<project>} type: ${SERVICE_TYPE:-project} in project: $GCP_PROJECT_ID"

# Normalize: strip a leading "projects/<proj>/" prefix to get the short name.
SHORT_NAME="${RESOURCE_NAME}"
if [[ "$SHORT_NAME" == projects/* ]]; then
  SHORT_NAME="${SHORT_NAME#projects/}"
  SHORT_NAME="${SHORT_NAME#*/}"
fi

# If no resource name is supplied, default to the project IAM policy.
if [ -z "${RESOURCE_NAME:-}" ]; then
  echo "RESOURCE_NAME not set. Defaulting to project IAM policy for $GCP_PROJECT_ID."
  policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>err.log) || {
    err_msg=$(cat err.log); rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "No IAM policy found for project \`$GCP_PROJECT_ID\`" \
      --arg details "gcloud projects get-iam-policy failed: $err_msg" \
      --arg severity "1" \
      --arg next_steps "Verify the credentials have resourcemanager.projects.getIamPolicy permission." \
      --arg expected "The project IAM policy should be readable" \
      --arg actual "No IAM policy could be retrieved for the project" \
      '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Resource role query completed. Found 1 issue."
    exit 0
  }
  echo "=== IAM policy for project ${GCP_PROJECT_ID} ==="
  echo "$policy" | jq -c '.bindings // []'
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# Determine the resource retrieval command based on SERVICE_TYPE.
command=""
case "${SERVICE_TYPE:-}" in
  ""|project|projects)
    command="gcloud projects get-iam-policy $SHORT_NAME --format=json"
    ;;
  storage|bucket|buckets)
    command="gsutil iam get gs://$SHORT_NAME"
    ;;
  run|cloudrun|cloud_run)
    command="gcloud run services get-iam-policy $SHORT_NAME --platform=managed --project=$GCP_PROJECT_ID --format=json"
    ;;
  gke|cluster|clusters)
    command="gcloud container clusters get-iam-policy $SHORT_NAME --project=$GCP_PROJECT_ID --format=json"
    ;;
  bigquery|dataset|datasets)
    # BigQuery datasets expose IAM via the dataset resource; use resource-level policy where available.
    command="gcloud projects get-iam-policy $GCP_PROJECT_ID --format=json"
    ;;
  *)
    command="gcloud projects get-iam-policy $GCP_PROJECT_ID --format=json"
    ;;
esac

echo "Running: $command"
if output=$(eval "$command" 2>err.log); then
  echo ""
  echo "=== IAM policy for resource ${SHORT_NAME} ==="
  echo "$output" | jq -c '.bindings // .policy.bindings // []'
else
  err_msg=$(cat err.log); rm -f err.log
  echo ""
  echo "Could not retrieve IAM policy for resource ${SHORT_NAME} of type ${SERVICE_TYPE:-project}: $err_msg"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No IAM policy found for resource \`$SHORT_NAME\`" \
    --arg details "Query failed for SERVICE_TYPE=${SERVICE_TYPE:-project}: $err_msg" \
    --arg severity "1" \
    --arg next_steps "Confirm the resource name and SERVICE_TYPE are correct and the credentials have the required getIamPolicy permission for this resource type." \
    --arg expected "The resource should exist and expose a readable IAM policy" \
    --arg actual "No IAM policy could be retrieved for the resource" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Resource role query completed. Found $(echo "$issues_json" | jq length) issue(s)."
