#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Lists all Cloud Composer environments in the project and flags any that are
# not in a healthy RUNNING state (ERROR, CREATING, UPDATING, DELETING, or
# otherwise degraded). Outputs a JSON array of issues to env_state_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"

OUTPUT_FILE="env_state_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer environment state for project: $GCP_PROJECT_ID"

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

echo "$envs" | jq -c '.[]' | while read -r env; do
  name=$(echo "$env" | jq -r '.name')
  short_name=$(echo "$name" | awk -F'/' '{print $NF}')
  location=$(echo "$env" | jq -r '.location')

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  echo "Checking state for environment: $short_name (location: $location)"
  state=$(gcloud composer environments describe "$short_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    --format='value(state)' 2>/dev/null || echo "UNKNOWN")

  if [ "$state" != "RUNNING" ]; then
    printf '{"title":"Cloud Composer environment `%s` is not healthy","expected":"Cloud Composer environment `%s` should be in a RUNNING state","actual":"Cloud Composer environment `%s` in location `%s` is in state `%s`","severity":3,"details":"Cloud Composer environment `%s` in location `%s` of project `%s` was found in state `%s`. Only the RUNNING state indicates a fully operational environment.","next_steps":"Investigate why the environment is not RUNNING. Check the environment `createTime`/`updateTime` for in-progress operations, review composer error logs, and verify the underlying infrastructure (GKE cluster, Cloud SQL, worker nodes) before restarting or updating the environment.","environment":"%s","state":"%s","issue_type":"environment_not_running"}\n' \
      "$short_name" "$short_name" "$short_name" "$location" "$state" \
      "$short_name" "$location" "$GCP_PROJECT_ID" "$state" "$short_name" "$state" >> "$TMP_FILE"
  fi
done

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "Environment state check complete. $(jq length "$OUTPUT_FILE") issue(s) found."
