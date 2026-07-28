#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="dataset_access_issues.json"
issues_json='[]'

echo "Checking dataset access for project: $GCP_PROJECT_ID"

datasets=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$datasets" | jq length)" -eq 0 ]; then
  echo "No datasets found."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

echo "$datasets" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  echo "Checking access for dataset: $dataset_id"

  access_entries=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null | jq '.access // []')

  has_public_access=false
  public_entries=$(echo "$access_entries" | jq '[.[] | select(.entity_type != null and (.entity_type == "allUsers" or .entity_type == "allAuthenticatedUsers") or (.groupByEmail == "allUsers" or .groupByEmail == "allAuthenticatedUsers") or (.iamMember == "allUsers" or .iamMember == "allAuthenticatedUsers"))]')

  # Also check via dataset access field directly
  public_via_iam=$(echo "$access_entries" | jq '[.[] | select(.groupByEmail == "allUsers" or .iamMember == "allUsers" or .groupByEmail == "allAuthenticatedUsers" or .iamMember == "allAuthenticatedUsers")]')

  if [ "$(echo "$public_via_iam" | jq length)" -gt 0 ]; then
    has_public_access=true
    entry_details=$(echo "$public_via_iam" | jq -c '.')
    echo "  Dataset $dataset_id has public access entries!"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "BigQuery dataset \`$dataset_id\` has publicly accessible IAM entries" \
      --arg details "Dataset \`$dataset_id\` in project \`$GCP_PROJECT_ID\` has public IAM members: allUsers or allAuthenticatedUsers. Full access entries: $entry_details" \
      --arg severity "2" \
      --arg next_steps "Remove public access from dataset \`$dataset_id\`. Use fine-grained access controls or authorized views instead." \
      --arg expected "Dataset should not be accessible to allUsers or allAuthenticatedUsers" \
      --arg actual "Dataset has public IAM entries" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_id,
         "issue_type": "public_access"
       }]')
  fi

  # Check for overly permissive roles
  excessive_roles=$(echo "$access_entries" | jq '[.[] | select(.role != null and (.role | test("owner|admin|editor|bigquery\\.admin", "i")))]')
  if [ "$(echo "$excessive_roles" | jq length)" -gt 0 ]; then
    echo "  Dataset $dataset_id has overly permissive roles!"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "BigQuery dataset \`$dataset_id\` has overly permissive access" \
      --arg details "Dataset \`$dataset_id\` in project \`$GCP_PROJECT_ID\` has roles that may be too permissive. Excessive entries: $(echo "$excessive_roles" | jq -c '.')" \
      --arg severity "2" \
      --arg next_steps "Review IAM roles on dataset \`$dataset_id\`. Prefer fine-grained roles like bigquery.dataViewer instead of owner/admin/editor." \
      --arg expected "Dataset should use least-privilege IAM roles" \
      --arg actual "Dataset has overly permissive roles" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_id,
         "issue_type": "overly_permissive"
       }]')
  fi
done

# Re-read issues_json from file since pipes create subshells
if [ -f "$OUTPUT_FILE" ]; then
  existing=$(cat "$OUTPUT_FILE")
else
  # Final write
  echo "Access check completed. Writing results."
fi

# For the final write, we need a simpler approach
final_issues='[]'
datasets_list=$(bq --project_id "$GCP_PROJECT_ID" ls --format=json 2>/dev/null || echo "[]")
echo "$datasets_list" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  access_entries=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null | jq '.access // []')
  
  has_public=$(echo "$access_entries" | jq '[.[] | select(.groupByEmail == "allUsers" or .iamMember == "allUsers" or .groupByEmail == "allAuthenticatedUsers" or .iamMember == "allAuthenticatedUsers")]')
  if [ "$(echo "$has_public" | jq length)" -gt 0 ]; then
    entry_details=$(echo "$has_public" | jq -c '.')
    final_issues=$(echo "$final_issues" | jq \
      --arg title "BigQuery dataset \`$dataset_id\` has publicly accessible IAM entries" \
      --arg details "Dataset \`$dataset_id\` in project \`$GCP_PROJECT_ID\` has public IAM members." \
      --arg severity "2" \
      --arg next_steps "Remove public access from dataset \`$dataset_id\`." \
      --arg expected "Dataset should not be accessible to allUsers or allAuthenticatedUsers" \
      --arg actual "Dataset has public IAM entries" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_id,
         "issue_type": "public_access"
       }]')
  fi

  has_excessive=$(echo "$access_entries" | jq '[.[] | select(.role != null and (.role | test("owner|admin|editor|bigquery\\.admin", "i")))]')
  if [ "$(echo "$has_excessive" | jq length)" -gt 0 ]; then
    excessive_details=$(echo "$has_excessive" | jq -c '.')
    final_issues=$(echo "$final_issues" | jq \
      --arg title "BigQuery dataset \`$dataset_id\` has overly permissive access" \
      --arg details "Dataset \`$dataset_id\` in project \`$GCP_PROJECT_ID\` has excessive roles." \
      --arg severity "2" \
      --arg next_steps "Review IAM roles on dataset \`$dataset_id\`." \
      --arg expected "Dataset should use least-privilege IAM roles" \
      --arg actual "Dataset has overly permissive roles" \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps,
         "expected": $expected,
         "actual": $actual,
         "dataset": $dataset_id,
         "issue_type": "overly_permissive"
       }]')
  fi
done

# For the subshell issue, let's just collect in a temp file
> "$OUTPUT_FILE"
echo "$datasets_list" | jq -c '.[]' | while read -r ds; do
  dataset_id=$(echo "$ds" | jq -r '.datasetReference.datasetId')
  access_entries=$(bq --project_id "$GCP_PROJECT_ID" show --format=json "$dataset_id" 2>/dev/null | jq '.access // []')
  
  has_public=$(echo "$access_entries" | jq '[.[] | select(.groupByEmail == "allUsers" or .iamMember == "allUsers" or .groupByEmail == "allAuthenticatedUsers" or .iamMember == "allAuthenticatedUsers")]')
  if [ "$(echo "$has_public" | jq length)" -gt 0 ]; then
    echo "{\"title\":\"BigQuery dataset \\\`$dataset_id\\\` has publicly accessible IAM entries\",\"details\":\"Dataset \\\`$dataset_id\\\` has public IAM members.\",\"severity\":2,\"next_steps\":\"Remove public access from dataset \\\`$dataset_id\\\`.\",\"expected\":\"Dataset should not be publicly accessible\",\"actual\":\"Dataset has public IAM entries\",\"dataset\":\"$dataset_id\",\"issue_type\":\"public_access\"}" >> "$OUTPUT_FILE"
  fi

  has_excessive=$(echo "$access_entries" | jq '[.[] | select(.role != null and (.role | test("owner|admin|editor|bigquery\\.admin", "i")))]')
  if [ "$(echo "$has_excessive" | jq length)" -gt 0 ]; then
    echo "{\"title\":\"BigQuery dataset \\\`$dataset_id\\\` has overly permissive access\",\"details\":\"Dataset \\\`$dataset_id\\\` has excessive roles.\",\"severity\":2,\"next_steps\":\"Review IAM roles on dataset \\\`$dataset_id\\\`.\",\"expected\":\"Dataset should use least-privilege IAM roles\",\"actual\":\"Dataset has overly permissive roles\",\"dataset\":\"$dataset_id\",\"issue_type\":\"overly_permissive\"}" >> "$OUTPUT_FILE"
  fi
done

# Convert line-by-line JSON to array
if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Access check completed. Found $(jq length "$OUTPUT_FILE") issues."
jq . "$OUTPUT_FILE"