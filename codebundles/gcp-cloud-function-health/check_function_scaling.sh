#!/usr/bin/env bash
# Check Cloud Function scaling and timeout configuration (gen1 + gen2).
# Flags: HTTP functions with long timeouts (cost/availability risk) and
# gen2 functions without a max instance cap (unbounded scaling cost risk).
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${HTTP_TIMEOUT_WARN_SECONDS:=300}"

ISSUES_FILE="function_scaling_issues.json"

echo "Checking Cloud Function scaling and timeout configuration for project: $GCP_PROJECT_ID"

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

  desc=$(gcloud functions describe "$name" --region="$region" $gen2_flag --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

  trigger=$(echo "$desc" | jq -r 'if .httpsTrigger then "HTTP" elif .eventTrigger then "event" elif .serviceConfig.uri then "HTTP" else "unknown" end')

  # --- Long-running HTTP function ---
  timeout_s=$(echo "$desc" | jq -r '.timeout // .serviceConfig.timeoutSeconds // empty' | sed 's/s$//')
  if [ "$trigger" = "HTTP" ] && [ -n "$timeout_s" ] && [ "$timeout_s" -gt "$HTTP_TIMEOUT_WARN_SECONDS" ] 2>/dev/null; then
    printf '{"title":"HTTP Cloud Function `%s` (%s) has a long timeout (%ss)","details":"HTTP function `%s` in region `%s` of project `%s` is configured with a %ss timeout (threshold: %ss). Long-running HTTP functions hold connections open and increase cost and failure surface.","severity":4,"next_steps":"Review whether function `%s` needs a %ss timeout. Consider moving long work to an event-driven function or a background service.","expected":"HTTP functions should complete within %ss","actual":"HTTP function timeout is %ss","function":"%s","issue_type":"long_http_timeout"}\n' \
      "$name" "$environment" "$timeout_s" "$name" "$region" "$GCP_PROJECT_ID" "$timeout_s" "$HTTP_TIMEOUT_WARN_SECONDS" "$name" "$timeout_s" "$HTTP_TIMEOUT_WARN_SECONDS" "$timeout_s" "$name" >> "$ISSUES_FILE"
  fi

  # --- Gen2 without max instance cap ---
  if [ "$environment" = "GEN_2" ]; then
    max_instances=$(echo "$desc" | jq -r '.serviceConfig.maxInstanceCount // empty')
    if [ -z "$max_instances" ]; then
      printf '{"title":"Gen2 Cloud Function `%s` has no max instance cap","details":"Gen2 function `%s` in region `%s` of project `%s` does not set serviceConfig.maxInstanceCount, so it can scale without bound. A traffic spike or retry storm can produce large unexpected bills.","severity":4,"next_steps":"Set a max instance limit on function `%s`: gcloud functions deploy %s --gen2 --region=%s --max-instances=<n>.","expected":"Gen2 functions should have a bounded max instance count","actual":"No max instance cap configured","function":"%s","issue_type":"unbounded_scaling"}\n' \
        "$name" "$name" "$region" "$GCP_PROJECT_ID" "$name" "$name" "$region" "$name" >> "$ISSUES_FILE"
    fi
  fi
done

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Scaling/timeout check complete. Found $(jq length "$ISSUES_FILE") issues."