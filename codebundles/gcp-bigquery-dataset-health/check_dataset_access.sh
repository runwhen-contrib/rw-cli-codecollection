#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="dataset_access_issues.json"

echo "Checking dataset access for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$datasets" | jq length)" -eq 0 ]; then
  echo "No datasets found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  echo "Checking access for dataset: $dataset_id"

  access_entries=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null | jq '.access // []')

  has_public=$(echo "$access_entries" | jq '[.[] | select(
    .groupByEmail == "allUsers" or
    .iamMember == "allUsers" or
    .specialGroup == "allUsers" or
    .groupByEmail == "allAuthenticatedUsers" or
    .iamMember == "allAuthenticatedUsers" or
    .specialGroup == "allAuthenticatedUsers"
  )]')

  if [ "$(echo "$has_public" | jq length)" -gt 0 ]; then
    echo "  Dataset $dataset_id has public access entries!"
    printf '{"title":"BigQuery dataset `%s` has publicly accessible IAM entries","details":"Dataset `%s` in project `%s` has public IAM members: allUsers or allAuthenticatedUsers.","severity":2,"next_steps":"Remove public access from dataset `%s`. Use fine-grained access controls or authorized views instead.","expected":"Dataset should not be accessible to allUsers or allAuthenticatedUsers","actual":"Dataset has public IAM entries","dataset":"%s","issue_type":"public_access"}\n' \
      "$dataset_id" "$dataset_id" "$GCP_PROJECT_ID" "$dataset_id" "$dataset_id" >> "$OUTPUT_FILE"
  fi

  has_excessive=$(echo "$access_entries" | jq '[.[] | select(.role != null and (.role | test("owner|admin|editor|bigquery\\.admin"; "i")))]')
  if [ "$(echo "$has_excessive" | jq length)" -gt 0 ]; then
    echo "  Dataset $dataset_id has overly permissive roles!"
    printf '{"title":"BigQuery dataset `%s` has overly permissive access","details":"Dataset `%s` in project `%s` has roles that may be too permissive.","severity":2,"next_steps":"Review IAM roles on dataset `%s`. Prefer fine-grained roles like bigquery.dataViewer instead of owner/admin/editor.","expected":"Dataset should use least-privilege IAM roles","actual":"Dataset has overly permissive roles","dataset":"%s","issue_type":"overly_permissive"}\n' \
      "$dataset_id" "$dataset_id" "$GCP_PROJECT_ID" "$dataset_id" "$dataset_id" >> "$OUTPUT_FILE"
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Access check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"