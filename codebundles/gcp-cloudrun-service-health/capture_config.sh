#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Report Cloud Run Service and Revision Configuration
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES       - Comma-separated Cloud Run service names, or 'All'.
#
# Dumps service and revision configuration (spec, annotations, concurrency,
# cpu/memory limits, env, service account, scaling) for all Cloud Run services
# into the report so it can be handed to an LLM for review. Also flags
# configuration risks: default compute service account and unbounded max scale.
#
# Writes:
#   config_issues.json  - JSON array of configuration issues
#   config_report.json  - JSON array of full service + revision configurations
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"
# shellcheck source=./cloudrun_common.sh
source "$(dirname "$0")/cloudrun_common.sh"

ISSUES_FILE="config_issues.json"
REPORT_FILE="config_report.json"
# NDJSON scratch file: one config object per line, slurped into a JSON array at
# the end. Seeding REPORT_FILE itself with "[]" would leave a stray empty array
# as the first element after the slurp.
REPORT_LINES="${REPORT_FILE}.ndjson"
echo "[]" > "$ISSUES_FILE"
: > "$REPORT_LINES"

echo "Capturing Cloud Run service and revision configuration for project: $GCP_PROJECT_ID"

while read -r svc; do
  [ -z "$svc" ] && continue
  name=$(echo "$svc" | jq -r '.metadata.name')
  region=$(echo "$svc" | jq -r '.metadata.labels["cloud.googleapis.com/location"] // "unknown"')

  # Full configuration dump for LLM review (service + its template/revision spec).
  echo "$svc" | jq -c '{
    name: .metadata.name,
    region: .metadata.labels["cloud.googleapis.com/location"],
    url: .status.url,
    annotations: .metadata.annotations,
    spec: .spec
  }' >> "$REPORT_LINES"

  # Configuration risk flags.
  service_account=$(echo "$svc" | jq -r '.spec.template.spec.serviceAccountName // empty')
  if [ -z "$service_account" ]; then
    add_issue "$ISSUES_FILE" "2" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` uses the default compute service account" \
      "Service \`$name\` in region \`$region\` does not set a dedicated service account (spec.template.spec.serviceAccountName is empty), so it runs as the default compute engine service account." \
      "Assign a least-privilege service account to the service: gcloud run services update $name --region=$region --project=$GCP_PROJECT_ID --service-account=<SA-EMAIL>." \
      "Cloud Run services should use a least-privilege dedicated service account" \
      "Service \`$name\` has no dedicated service account configured"
  fi

  max_scale=$(echo "$svc" | jq -r '.spec.template.metadata.annotations["autoscaling.knative.dev/maxScale"] // empty')
  if [ -z "$max_scale" ]; then
    add_issue "$ISSUES_FILE" "1" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has no maximum instance limit" \
      "Service \`$name\` in region \`$region\` has no autoscaling.knative.dev/maxScale annotation set, so it can scale without an upper bound (cost risk)." \
      "Set a maximum instance count appropriate for the workload: gcloud run services update $name --region=$region --project=$GCP_PROJECT_ID --max-instances=<N>." \
      "Cloud Run services should define an upper bound on scaling" \
      "Service \`$name\` has no max-instances limit configured"
  fi
done < <(discover_services || echo "")

if [ -s "$REPORT_LINES" ]; then
  jq -s '.' "$REPORT_LINES" > "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi
rm -f "$REPORT_LINES"

# Emit the captured configuration on stdout so the runbook's
# "RW.Core.Add Pre To Report" actually carries it into the report for LLM review.
service_count=$(jq length "$REPORT_FILE")
echo "Captured configuration for $service_count Cloud Run service(s):"
jq '.' "$REPORT_FILE"

echo "Configuration capture complete. Found $(jq length "$ISSUES_FILE") issues."
