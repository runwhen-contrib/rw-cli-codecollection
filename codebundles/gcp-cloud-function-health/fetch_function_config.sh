#!/usr/bin/env bash
# Fetch full configuration for all Cloud Functions (gen1 + gen2) in the project.
# Emits function_config_report.json (all configs) and function_config_issues.json
# (misconfigurations worth flagging).
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

REPORT_FILE="function_config_report.json"
ISSUES_FILE="function_config_issues.json"

echo "Fetching Cloud Function configurations for project: $GCP_PROJECT_ID"

functions=$(gcloud functions list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$functions" | jq length)" -eq 0 ]; then
  echo "No Cloud Functions found."
  echo "[]" > "$REPORT_FILE"
  echo "[]" > "$ISSUES_FILE"
  exit 0
fi

> "$REPORT_FILE"
> "$ISSUES_FILE"

echo "$functions" | jq -c '.[]' | while read -r fn; do
  name=$(echo "$fn" | jq -r '.name | split("/") | .[-1]')
  region=$(echo "$fn" | jq -r '.name | split("/") | .[3]')
  environment=$(echo "$fn" | jq -r '.environment // "GEN_1"')

  gen2_flag=""
  if [ "$environment" = "GEN_2" ]; then
    gen2_flag="--gen2"
  fi

  echo "Describing $name ($environment) in $region"
  desc=$(gcloud functions describe "$name" --region="$region" $gen2_flag --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  echo "$desc" | jq -c --arg n "$name" --arg r "$region" --arg e "$environment" '. + {shortName: $n, region: $r, environment: $e}' >> "$REPORT_FILE"

  # Flag: no dedicated service account (falls back to the default compute SA,
  # which typically holds roles/editor -- overly broad for a function)
  sa=$(echo "$desc" | jq -r '.serviceAccountEmail // .serviceConfig.serviceAccountEmail // empty')
  if [ -z "$sa" ]; then
    printf '{"title":"Cloud Function `%s` (%s) has no dedicated service account","details":"Function `%s` in region `%s` of project `%s` does not specify a service account and falls back to the default compute service account, which usually carries broad project-level roles.","severity":3,"next_steps":"Create a dedicated service account with least-privilege roles and assign it to function `%s`.","expected":"Functions should run under dedicated least-privilege service accounts","actual":"Function uses the default compute service account","function":"%s","issue_type":"default_service_account"}\n' \
      "$name" "$environment" "$name" "$region" "$GCP_PROJECT_ID" "$name" "$name" >> "$ISSUES_FILE"
  fi
done

jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Configuration fetch complete. $(jq length "$REPORT_FILE") functions described, $(jq length "$ISSUES_FILE") issues."