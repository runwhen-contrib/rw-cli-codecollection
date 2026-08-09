#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Cloud Run Services Ready and Serving Traffic in GCP Project
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES       - Comma-separated Cloud Run service names, or 'All'.
#
# Checks the top-level Ready condition for each Cloud Run service and verifies
# traffic is actually routed to a Ready revision that can serve requests,
# flagging services that are not Ready or serving 0% to the latest ready revision.
#
# Writes:
#   services_serving_issues.json  - JSON array of issues
#   services_serving_report.json  - JSON array of services inspected
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"
# shellcheck source=./cloudrun_common.sh
source "$(dirname "$0")/cloudrun_common.sh"

ISSUES_FILE="services_serving_issues.json"
REPORT_FILE="services_serving_report.json"
echo "[]" > "$ISSUES_FILE"
# NDJSON scratch file: one object per line, slurped into a JSON array at the end.
# Seeding REPORT_FILE itself with "[]" would leave a stray empty array as the
# first element after the slurp.
REPORT_LINES="${REPORT_FILE}.ndjson"
: > "$REPORT_LINES"

echo "Checking Cloud Run service readiness and traffic routing in project: $GCP_PROJECT_ID"

while read -r svc; do
  [ -z "$svc" ] && continue
  name=$(echo "$svc" | jq -r '.metadata.name')
  region=$(echo "$svc" | jq -r '.metadata.labels["cloud.googleapis.com/location"] // "unknown"')

  echo "$svc" | jq -c '.' >> "$REPORT_LINES"

  ready=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown"')
  if [ "$ready" != "True" ]; then
    reason=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].reason // "Unknown"')
    message=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].message // "Unknown reason"')
    add_issue "$ISSUES_FILE" "2" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` is not Ready" \
      "Service \`$name\` in region \`$region\` of project \`$GCP_PROJECT_ID\` reports Ready=$ready (reason=$reason). Condition message: $message" \
      "Inspect the service and its revisions: gcloud run services describe $name --region=$region --project=$GCP_PROJECT_ID. Check revision conditions and container logs." \
      "Cloud Run services should have a Ready condition of True" \
      "Service \`$name\` reports Ready=$ready"
  fi

  # Cloud Run keeps `latestReadyRevisionName` pointing at the revision that is
  # actually routed traffic, so it always reports 100% and can never flag this on
  # its own. The newest revision is `latestCreatedRevisionName`; when that one is
  # Ready but receives no traffic, the service is not serving its latest code.
  latest_ready=$(echo "$svc" | jq -r '.status.latestReadyRevisionName // empty')
  latest_created=$(echo "$svc" | jq -r '.status.latestCreatedRevisionName // empty')
  url=$(echo "$svc" | jq -r '.status.url // "unknown"')

  if [ -n "$latest_created" ] && [ "$latest_created" != "$latest_ready" ] \
     && [ "$(revision_ready "$latest_created" "$region")" = "True" ]; then
    traffic_on_latest=$(echo "$svc" | jq -r --arg rev "$latest_created" \
      '[.status.traffic[]? | select(.revisionName == $rev)][0].percent // 0')

    if [ "$traffic_on_latest" = "0" ]; then
      add_issue "$ISSUES_FILE" "3" \
        "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` is not serving traffic from its latest ready revision" \
        "Service \`$name\` in region \`$region\` (url=$url) has newest Ready revision \`$latest_created\` but 0% of traffic is routed to it, so requests are served by the older revision \`${latest_ready:-unknown}\` instead of the latest code." \
        "Check the traffic split: gcloud run services describe $name --region=$region --project=$GCP_PROJECT_ID --format=json | jq '.status.traffic'. Route traffic to the ready revision or fix the latest revision." \
        "Latest ready revision should receive traffic" \
        "Latest ready revision \`$latest_created\` receives 0% of traffic"
    fi
  fi
done < <(discover_services || echo "")

if [ -s "$REPORT_LINES" ]; then
  jq -s '.' "$REPORT_LINES" > "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi
rm -f "$REPORT_LINES"

echo "Ready/serving check complete. Found $(jq length "$ISSUES_FILE") issues."
