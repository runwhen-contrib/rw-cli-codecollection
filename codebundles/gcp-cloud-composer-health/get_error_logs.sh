#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project containing Cloud Composer environments
#   ENV_NAME                 - optional; pin to a single environment name, or 'All'
#   LOG_LOOKBACK_WINDOW_DAYS - number of days back to scan Cloud Logging (default 14)
#
# Scans Cloud Logging (resource.type=cloud_composer_environment) for ERROR and
# higher severity entries over the lookback window and groups them per
# environment, surfacing the most common failures.
# Outputs a JSON array of issues to error_logs_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${LOG_LOOKBACK_WINDOW_DAYS:=14}"

OUTPUT_FILE="error_logs_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Scanning Cloud Logging for Cloud Composer error logs (last ${LOG_LOOKBACK_WINDOW_DAYS} days) in project: $GCP_PROJECT_ID"

filter="resource.type=cloud_composer_environment AND severity>=ERROR"

if [ "$ENV_NAME" != "All" ]; then
  filter="resource.type=cloud_composer_environment AND resource.labels.environment_name=\"${ENV_NAME}\" AND severity>=ERROR"
fi

logs_raw=$(gcloud logging read "$filter" \
  --project="$GCP_PROJECT_ID" \
  --freshness="${LOG_LOOKBACK_WINDOW_DAYS}d" \
  --order=desc \
  --limit=1000 \
  --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$logs_raw" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer error logs found in the last ${LOG_LOOKBACK_WINDOW_DAYS} days."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

# Group logs per environment name and derive a short message signature for each.
grouped=$(echo "$logs_raw" | jq -r '
  group_by(.resource.labels.environment_name // "unknown")
  | map({
      environment: (.[0].resource.labels.environment_name // "unknown"),
      count: length,
      sample: (.[0].textPayload // .[0].jsonPayload // .[0].protoPayload.status.message // "no message"),
      latest: (map(.timestamp) | max)
    })
  | .[] 
' 2>/dev/null)

while read -r env_count env_json; do
  [ -z "$env_json" ] && continue
  # env_json is a JSON object per environment (single-line).
  environment=$(echo "$env_json" | jq -r '.environment')
  count=$(echo "$env_json" | jq -r '.count')
  sample=$(echo "$env_json" | jq -r '.sample' | tr '\n' ' ' | cut -c1-500)

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$environment" ]; then
    continue
  fi

  printf '{"title":"Error logs found for Cloud Composer environment `%s`","expected":"Cloud Composer environment `%s` should have no ERROR or higher severity logs in the last %s days","actual":"Environment `%s` has %s ERROR or higher severity log entrie(s) in the last %s days","severity":3,"details":"Environment `%s` in project `%s` produced %s ERROR or higher severity log entries within the last %s days. Sample message: %s","next_steps":"Open Cloud Logging filtered to resource.type=cloud_composer_environment and resource.labels.environment_name=\"%s\" severity>=ERROR over the last %s days, review the grouped failure signatures, and remediate the underlying scheduler/worker/DAG errors.","environment":"%s","error_count":%s,"issue_type":"environment_error_logs"}\n' \
    "$environment" "$environment" "$LOG_LOOKBACK_WINDOW_DAYS" \
    "$environment" "$count" "$LOG_LOOKBACK_WINDOW_DAYS" \
    "$environment" "$GCP_PROJECT_ID" "$count" "$LOG_LOOKBACK_WINDOW_DAYS" "$sample" \
    "$environment" "$LOG_LOOKBACK_WINDOW_DAYS" "$environment" "$count" >> "$TMP_FILE"
done < <(echo "$grouped")

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "Error log scan complete. $(jq length "$OUTPUT_FILE") environment(s) with error logs."
