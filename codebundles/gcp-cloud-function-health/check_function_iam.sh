#!/usr/bin/env bash
# Check IAM policies on all Cloud Functions (gen1 + gen2) for public invoker
# access (allUsers / allAuthenticatedUsers).
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="function_iam_issues.json"

echo "Checking Cloud Function IAM policies for project: $GCP_PROJECT_ID"

functions=$(gcloud functions list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$functions" | jq length)" -eq 0 ]; then
  echo "No Cloud Functions found."
  echo "[]" > "$ISSUES_FILE"
  exit 0
fi

> "$ISSUES_FILE"

echo "$functions" | jq -c '.[]' | while read -r fn; do
  name=$(echo "$fn" | jq -r '.name | split("/") | .[-1]')
  region=$(echo "$fn" | jq -r '.name | split("/") | .[3]')
  environment=$(echo "$fn" | jq -r '.environment // "GEN_1"')

  gen2_flag=""
  if [ "$environment" = "GEN_2" ]; then
    gen2_flag="--gen2"
  fi

  echo "Checking IAM policy for $name ($environment) in $region"
  policy=$(gcloud functions get-iam-policy "$name" --region="$region" $gen2_flag --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

  public=$(echo "$policy" | jq '[.bindings[]? | select(.members[]? == "allUsers" or .members[]? == "allAuthenticatedUsers")]')
  if [ "$(echo "$public" | jq length)" -gt 0 ]; then
    echo "  Function $name is publicly invocable!"
    printf '{"title":"Cloud Function `%s` (%s) is publicly invocable","details":"Function `%s` in region `%s` of project `%s` grants invoker permissions to allUsers or allAuthenticatedUsers. Anyone on the internet can invoke this function.","severity":2,"next_steps":"Remove public IAM bindings from function `%s`: gcloud functions remove-iam-policy-binding %s --region=%s --member=allUsers --role=roles/cloudfunctions.invoker. If public access is intended, add authentication at the application layer.","expected":"Functions should require authenticated invocation","actual":"Function is publicly invocable","function":"%s","issue_type":"public_invoker"}\n' \
      "$name" "$environment" "$name" "$region" "$GCP_PROJECT_ID" "$name" "$name" "$region" "$name" >> "$ISSUES_FILE"
  fi
done

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "IAM check complete. Found $(jq length "$ISSUES_FILE") issues."