#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# List Failed Cloud Run Revisions in GCP Project
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES       - Comma-separated Cloud Run service names, or 'All'.
#
# Enumerates Cloud Run revisions whose Ready condition is not True (e.g.
# ContainerStartupFailure, HealthCheckContainerFailed, ResourceExhausted),
# surfaceing revision name, service, generation, and the failing message.
#
# Writes:
#   failed_revisions_issues.json  - JSON array of issues
#   failed_revisions_report.json  - JSON array of all revisions inspected
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"
# shellcheck source=./cloudrun_common.sh
source "$(dirname "$0")/cloudrun_common.sh"

ISSUES_FILE="failed_revisions_issues.json"
REPORT_FILE="failed_revisions_report.json"
echo "[]" > "$ISSUES_FILE"
# NDJSON scratch file: one object per line, slurped into a JSON array at the end.
# Seeding REPORT_FILE itself with "[]" would leave a stray empty array as the
# first element after the slurp.
REPORT_LINES="${REPORT_FILE}.ndjson"
: > "$REPORT_LINES"

echo "Listing failed Cloud Run revisions in project: $GCP_PROJECT_ID"

while read -r svc; do
  [ -z "$svc" ] && continue
  name=$(echo "$svc" | jq -r '.metadata.name')
  region=$(echo "$svc" | jq -r '.metadata.labels["cloud.googleapis.com/location"] // "unknown"')

  revisions=$(gcloud run revisions list \
    --service="$name" \
    --region="$region" \
    --platform=managed \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>/dev/null || echo "[]")

  # Append all revisions to the report for LLM review.
  echo "$revisions" | jq -c --arg svc "$name" --arg region "$region" \
    '.[] | . + {serviceName: $svc, region: $region}' >> "$REPORT_LINES" 2>/dev/null || true

  echo "$revisions" | jq -c '.[]' 2>/dev/null | while read -r rev; do
    [ -z "$rev" ] && continue
    rev_name=$(echo "$rev" | jq -r '.metadata.name')
    generation=$(echo "$rev" | jq -r '.metadata.generation // "unknown"')
    ready=$(echo "$rev" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown"')

    if [ "$ready" != "True" ]; then
      reason=$(echo "$rev" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].reason // "Unknown"')
      message=$(echo "$rev" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].message // "Unknown reason"')

      severity=2
      case "$reason" in
        ContainerStartupFailure|HealthCheckContainerFailed|ResourceExhausted)
          severity=3
          ;;
      esac

      add_issue "$ISSUES_FILE" "$severity" \
        "Cloud Run revision \`$rev_name\` of service \`$name\` in project \`$GCP_PROJECT_ID\` is not Ready" \
        "Revision \`$rev_name\` (generation $generation) of service \`$name\` in region \`$region\` of project \`$GCP_PROJECT_ID\` reports Ready=$ready (reason=$reason). Condition message: $message" \
        "Inspect the revision and its container logs: gcloud run revisions describe $rev_name --region=$region --project=$GCP_PROJECT_ID; gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=$name' --freshness=14d" \
        "Cloud Run revisions should have a Ready condition of True" \
        "Revision \`$rev_name\` reports Ready=$ready"
    fi
  done
done < <(discover_services || echo "")

# Finalize report file as a JSON array.
if [ -s "$REPORT_LINES" ]; then
  jq -s '.' "$REPORT_LINES" > "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi
rm -f "$REPORT_LINES"

echo "Failed revision check complete. Found $(jq length "$ISSUES_FILE") issues."
