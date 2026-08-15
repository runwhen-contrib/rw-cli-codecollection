#!/usr/bin/env bash
# Detect failed Cloud Function builds and deployments.
#  - Gen1: deployment failures surface in function state/stateMessages
#  - Gen2: build failures surface as FAILED Cloud Build jobs
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="function_build_issues.json"

echo "Checking for failed Cloud Function builds and deployments for project: $GCP_PROJECT_ID"

> "$ISSUES_FILE"

# --- Deployment state failures (both generations) ---
functions=$(gcloud functions list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
echo "$functions" | jq -c '.[] | select(.state != "ACTIVE" or .status != "ACTIVE")' | while read -r fn; do
  [ -z "$fn" ] && continue
  name=$(echo "$fn" | jq -r '.name | split("/") | .[-1]')
  region=$(echo "$fn" | jq -r '.name | split("/") | .[3]')
  state=$(echo "$fn" | jq -r '.state // .status // "UNKNOWN"')
  messages=$(echo "$fn" | jq -c '[.stateMessages[]? | {severity: .severity, type: .type, message: .message}]')

  printf '{"title":"Cloud Function `%s` deployment is in state %s","details":"Function `%s` in region `%s` of project `%s` is in state %s. State messages: %s","severity":2,"next_steps":"Review the state messages for function `%s`: gcloud functions describe %s --region=%s --format=json. Redeploy the function after fixing the underlying build or configuration issue.","expected":"Functions should deploy to ACTIVE state","actual":"Function deployment is not ACTIVE","function":"%s","issue_type":"deployment_failed"}\n' \
    "$name" "$state" "$name" "$region" "$GCP_PROJECT_ID" "$state" "$messages" "$name" "$name" "$region" "$name" >> "$ISSUES_FILE"
done

# --- Failed Cloud Build jobs (gen2 builds go through Cloud Build) ---
builds=$(gcloud builds list --project="$GCP_PROJECT_ID" --filter="status=FAILURE" --limit=20 --format=json 2>/dev/null || echo "[]")
echo "$builds" | jq -c '.[]' | while read -r build; do
  [ -z "$build" ] && continue
  build_id=$(echo "$build" | jq -r '.id')
  create_time=$(echo "$build" | jq -r '.createTime // "unknown"')
  log_url=$(echo "$build" | jq -r '.logUrl // "no log URL"')
  tags=$(echo "$build" | jq -c '.tags // []')

  printf '{"title":"Failed Cloud Build `%s` may indicate a broken function deployment","details":"Cloud Build job `%s` (created %s) in project `%s` FAILED. Tags: %s. Build log: %s","severity":3,"next_steps":"Review the failed build log at %s. If it belongs to a Cloud Function deployment, fix the source or build configuration and redeploy.","expected":"Function builds should succeed","actual":"Cloud Build job failed","build_id":"%s","issue_type":"build_failed"}\n' \
    "$build_id" "$build_id" "$create_time" "$GCP_PROJECT_ID" "$tags" "$log_url" "$log_url" "$build_id" >> "$ISSUES_FILE"
done

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Build/deployment check complete. Found $(jq length "$ISSUES_FILE") issues."