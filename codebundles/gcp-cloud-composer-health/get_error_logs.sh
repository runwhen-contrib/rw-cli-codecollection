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

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${LOG_LOOKBACK_WINDOW_DAYS:=14}"

OUTPUT_FILE="error_logs_issues.json"

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
  exit 0
fi

# Group logs per environment and build issues directly with jq (so embedded
# quotes/newlines in the log payloads are escaped correctly, unlike printf).
echo "$logs_raw" | jq -c \
  --arg ename "$ENV_NAME" \
  --arg project "$GCP_PROJECT_ID" \
  --arg days "$LOG_LOOKBACK_WINDOW_DAYS" \
  '
  def first_line: (if type == "object" then tostring else . end) | split("\n") | map(select(length > 0)) | .[0] // "";
  group_by(.resource.labels.environment_name // "unknown")
  | map({
      environment: (.[0].resource.labels.environment_name // "unknown"),
      count: length,
      samples: ([.[] | (.textPayload // .jsonPayload // .protoPayload.status.message // "no message") | first_line | gsub("[[:space:]]+"; " ") | .[0:200]] | unique | .[0:5])
    })
  | map(select(($ename == "All") or (.environment == $ename)))
  | map({
      title: ("Error logs found for Cloud Composer environment `" + .environment + "`"),
      expected: ("Cloud Composer environment `" + .environment + "` should have no ERROR or higher severity logs in the last " + $days + " days"),
      actual: ("Environment `" + .environment + "` has " + (.count | tostring) + " ERROR or higher severity log entrie(s) in the last " + $days + " days"),
      severity: 3,
      details: ("Environment `" + .environment + "` in project " + $project + " produced " + (.count | tostring) + " ERROR or higher severity log entries within the last " + $days + " days. Sample messages: " + (.samples | join(" | "))),
      next_steps: ("Open Cloud Logging filtered to resource.type=cloud_composer_environment and resource.labels.environment_name=\"" + .environment + "\" severity>=ERROR over the last " + $days + " days, review the grouped failure signatures, and remediate the underlying scheduler/worker/DAG errors."),
      environment: .environment,
      error_count: .count,
      samples: .samples,
      issue_type: "environment_error_logs"
    })
  ' > "$OUTPUT_FILE"

echo "Error log scan complete. $(jq length "$OUTPUT_FILE") environment(s) with error logs."

# Verbose, human-readable summary (this is what an LLM reads).
jq -r '.[] | "Environment: \(.environment)\n  Total ERROR entries: \(.error_count)\n  Sample messages:\n" + (.samples | map("    - \(.)") | join("\n")) + "\n"' "$OUTPUT_FILE"
