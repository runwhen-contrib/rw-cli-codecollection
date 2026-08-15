#!/usr/bin/env bash
# Check the underlying Cloud Run service health for gen2 Cloud Functions.
# Gen2 functions run on Cloud Run -- a function can be ACTIVE at the functions
# API level while its Cloud Run revision is failing (container errors, scaling
# issues, missing traffic).
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="gen2_run_health_issues.json"
REPORT_FILE="gen2_run_health_report.json"

echo "Checking gen2 Cloud Run service health for project: $GCP_PROJECT_ID"

functions=$(gcloud functions list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
gen2_functions=$(echo "$functions" | jq '[.[] | select(.environment == "GEN_2")]')
if [ "$(echo "$gen2_functions" | jq length)" -eq 0 ]; then
  echo "No gen2 Cloud Functions found."
  echo "[]" > "$ISSUES_FILE"
  echo "[]" > "$REPORT_FILE"
  exit 0
fi

> "$ISSUES_FILE"
> "$REPORT_FILE"

echo "$gen2_functions" | jq -c '.[]' | while read -r fn; do
  name=$(echo "$fn" | jq -r '.name | split("/") | .[-1]')
  region=$(echo "$fn" | jq -r '.name | split("/") | .[3]')

  echo "Checking Cloud Run service for gen2 function $name in $region"
  svc=$(gcloud run services describe "$name" --region="$region" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  echo "$svc" | jq -c --arg n "$name" --arg r "$region" '. + {functionName: $n, region: $r}' >> "$REPORT_FILE"

  # Ready condition
  ready=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "Ready")] | .[0].status // "Unknown"')
  if [ "$ready" != "True" ]; then
    reason=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "Ready")] | .[0].message // "Unknown reason"')
    printf '{"title":"Gen2 Cloud Function `%s` Cloud Run service is not Ready","details":"The Cloud Run service backing gen2 function `%s` in region `%s` of project `%s` reports Ready=%s: %s","severity":2,"next_steps":"Inspect the Cloud Run service for `%s` in region `%s`: gcloud run services describe %s --region=%s. Check revision logs and container startup probes.","expected":"Gen2 function Cloud Run services should be Ready","actual":"Cloud Run service is not Ready","function":"%s","issue_type":"gen2_run_not_ready"}\n' \
      "$name" "$name" "$region" "$GCP_PROJECT_ID" "$ready" "$reason" "$name" "$region" "$name" "$region" "$name" >> "$ISSUES_FILE"
  fi

  # Zero traffic on latest revision
  latest_ready=$(echo "$svc" | jq -r '.status.latestReadyRevisionName // empty')
  traffic_on_latest=$(echo "$svc" | jq -r --arg rev "$latest_ready" '[.status.traffic[]? | select(.revisionName == $rev)] | .[0].percent // 0')
  if [ -n "$latest_ready" ] && [ "$traffic_on_latest" = "0" ]; then
    printf '{"title":"Gen2 Cloud Function `%s` latest revision receives no traffic","details":"Gen2 function `%s` in region `%s` of project `%s` has latest ready revision `%s` but 0%% of traffic is routed to it.","severity":3,"next_steps":"Check traffic split for Cloud Run service `%s`: gcloud run services describe %s --region=%s --format=json.","expected":"Latest ready revision should receive traffic","actual":"Latest ready revision receives 0%% of traffic","function":"%s","issue_type":"gen2_no_traffic_on_latest"}\n' \
      "$name" "$name" "$region" "$GCP_PROJECT_ID" "$latest_ready" "$name" "$name" "$region" "$name" >> "$ISSUES_FILE"
  fi
done

jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Gen2 health check complete. Found $(jq length "$ISSUES_FILE") issues."