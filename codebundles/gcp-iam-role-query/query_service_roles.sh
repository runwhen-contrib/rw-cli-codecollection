#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that provides the IAM context.
#   SERVICE_TYPE     - GCP service type (e.g. storage, bigquery, run).
#   RESOURCE_NAME    - Optional resource name; if empty, a wildcard, or "All",
#                      iterate over all resources of SERVICE_TYPE in the project.
#
# Queries the IAM bindings on a named GCP service type across the project,
# filtering by the requested resource kind. Findings are printed to stdout and
# failures are reported as informational (severity 1) issues.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="service_role_issues.json"
issues_json='[]'

echo "Querying IAM roles for service type: ${SERVICE_TYPE:-<unset>} in project: $GCP_PROJECT_ID"

if [ -z "${SERVICE_TYPE:-}" ]; then
  echo "SERVICE_TYPE is not set. This task requires a GCP service type (e.g. storage, bigquery, run)."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Missing SERVICE_TYPE for IAM role query in \`$GCP_PROJECT_ID\`" \
    --arg details "The SERVICE_TYPE runtime variable is empty, so no resources could be listed." \
    --arg severity "1" \
    --arg next_steps "Provide a GCP service type such as storage, bigquery, or run via the SERVICE_TYPE variable and re-run." \
    --arg expected "SERVICE_TYPE should reference a supported GCP service type" \
    --arg actual "SERVICE_TYPE was empty" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Determine the list command and how to extract resource names for this service type.
list_cmd=""
name_expr=""
iam_getter="get_iam_project"
case "${SERVICE_TYPE:-}" in
  storage|bucket|buckets)
    list_cmd="gcloud storage buckets list --project=$GCP_PROJECT_ID --format=json"
    name_expr='.[].name'
    iam_getter="get_iam_storage"
    ;;
  bigquery|dataset|datasets)
    list_cmd="bq ls --project_id=$GCP_PROJECT_ID --format=json"
    name_expr='.[].id'
    iam_getter="get_iam_bigquery"
    ;;
  run|cloudrun|cloud_run)
    list_cmd="gcloud run services list --project=$GCP_PROJECT_ID --format=json"
    name_expr='.[].metadata.name'
    iam_getter="get_iam_run"
    ;;
  gke|cluster|clusters)
    list_cmd="gcloud container clusters list --project=$GCP_PROJECT_ID --format=json"
    name_expr='[.[]."name"]'
    iam_getter="get_iam_gke"
    ;;
  *)
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Unsupported SERVICE_TYPE \`$SERVICE_TYPE\` in \`$GCP_PROJECT_ID\`" \
      --arg details "SERVICE_TYPE was set to '$SERVICE_TYPE', which is not a supported service type for this query." \
      --arg severity "1" \
      --arg next_steps "Use a supported service type: storage, bigquery, run, or gke." \
      --arg expected "SERVICE_TYPE should be a supported GCP service type" \
      --arg actual "SERVICE_TYPE '$SERVICE_TYPE' is not supported" \
      '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Service role query completed. Found 1 issue."
    exit 0
    ;;
esac

# Shared resource-level IAM getters
get_iam_project() {
  gcloud projects get-iam-policy "$1" --format=json
}
get_iam_storage() {
  gsutil iam get "gs://$1"
}
get_iam_bigquery() {
  # Dataset identifier arrives as "project:dataset" or just the id.
  bq show --format=json "${1#*:}"
}
get_iam_run() {
  gcloud run services get-iam-policy "${1##*/}" --platform=managed --project="$GCP_PROJECT_ID" --format=json
}
get_iam_gke() {
  gcloud container clusters get-iam-policy "$1" --project="$GCP_PROJECT_ID" --format=json
}

echo "Listing resources of type ${SERVICE_TYPE}..."
if ! list_output=$(eval "$list_cmd" 2>err.log); then
  err_msg=$(cat err.log); rm -f err.log
  echo "Could not list resources of type ${SERVICE_TYPE}: $err_msg"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Could not list resources of type \`$SERVICE_TYPE\` in \`$GCP_PROJECT_ID\`" \
    --arg details "Resource listing failed: $err_msg" \
    --arg severity "1" \
    --arg next_steps "Verify the service credentials have permission to list resources of this type." \
    --arg expected "Resources of the requested service type should be listable" \
    --arg actual "Resource listing failed for the service type" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Service role query completed. Found 1 issue."
  exit 0
fi

# Extract the resource names for this service type.
# name_expr may be a plain expr or an array expression ("[.[]"name"]").
if [[ "$name_expr" == \[* ]]; then
  names=$(echo "$list_output" | jq -c "$name_expr")
else
  names=$(echo "$list_output" | jq -c "[.[] | $name_expr]")
fi

total=$(echo "$names" | jq length)
echo "Discovered $total resource(s) of type ${SERVICE_TYPE}."

# Filter to the requested resource if RESOURCE_NAME is a specific name.
filtered_names="$names"
if [ -n "${RESOURCE_NAME:-}" ] && [ "$RESOURCE_NAME" != "All" ] && [ "$RESOURCE_NAME" != "*" ] && [ "$RESOURCE_NAME" != "all" ]; then
  requested="$(basename "${RESOURCE_NAME%/}")"
  filtered_names=$(echo "$names" | jq -c --arg req "$requested" '[.[] | select(. == $req or (split("/") | last) == $req)]')
  echo "Filtering to resource(s) matching: $requested"
fi

count=$(echo "$filtered_names" | jq length)
if [ "$count" -eq 0 ]; then
  echo "No resources matched the requested filter for type ${SERVICE_TYPE}."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No resources of type \`$SERVICE_TYPE\` matched the query in \`$GCP_PROJECT_ID\`" \
    --arg details "No resource of type '$SERVICE_TYPE' was found matching RESOURCE_NAME '${RESOURCE_NAME:-All}'." \
    --arg severity "1" \
    --arg next_steps "Confirm the resource name and service type, then re-run the query." \
    --arg expected "At least one resource of the requested type should exist" \
    --arg actual "No matching resources were found" \
    '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
fi

# For each matched resource, retrieve its IAM policy.
echo ""
for name in $(echo "$filtered_names" | jq -r '.[]'); do
  echo "=== IAM bindings for ${SERVICE_TYPE} resource: ${name} ==="
  if policy=$("$iam_getter" "$name" 2>err.log); then
    echo "$policy" | jq -c '.bindings // .policy.bindings // []'
  else
    err_msg=$(cat err.log); rm -f err.log
    echo "  Could not retrieve IAM policy for $name: $err_msg"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "No IAM policy found for \`$SERVICE_TYPE\` resource \`$name\`" \
      --arg details "IAM policy query failed for resource '$name': $err_msg" \
      --arg severity "1" \
      --arg next_steps "Confirm the resource exists and the credentials have getIamPolicy permission on this resource type." \
      --arg expected "Each resource should expose a readable IAM policy" \
      --arg actual "IAM policy could not be retrieved for the resource" \
      '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"next_steps":$next_steps,"expected":$expected,"actual":$actual}]')
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Service role query completed. Found $(echo "$issues_json" | jq length) issue(s)."
