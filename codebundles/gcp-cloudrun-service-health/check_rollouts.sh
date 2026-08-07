#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Detect Troubled or Aborted Cloud Run Rollouts in GCP Project
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES       - Comma-separated Cloud Run service names, or 'All'.
#
# Identifies rollouts that are in a non-Serving state during a deploy window:
# the latest configuration has not been rolled out (generation not reconciled),
# a revision was created but never became Ready, or traffic has rolled back to a
# prior revision while the latest ready revision serves nothing.
#
# Writes:
#   rollouts_issues.json          - JSON array of issues
#   rollouts_report.json          - JSON array of rollout status per service
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"
# shellcheck source=./cloudrun_common.sh
source "$(dirname "$0")/cloudrun_common.sh"

ISSUES_FILE="rollouts_issues.json"
REPORT_FILE="rollouts_report.json"
echo "[]" > "$ISSUES_FILE"
echo "[]" > "$REPORT_FILE"

echo "Detecting troubled or aborted Cloud Run rollouts in project: $GCP_PROJECT_ID"

while read -r svc; do
  [ -z "$svc" ] && continue
  name=$(echo "$svc" | jq -r '.metadata.name')
  region=$(echo "$svc" | jq -r '.metadata.labels["cloud.googleapis.com/location"] // "unknown"')

  generation=$(echo "$svc" | jq -r '.metadata.generation // "0"')
  observed_generation=$(echo "$svc" | jq -r '.status.observedGeneration // "0"')
  latest_created=$(echo "$svc" | jq -r '.status.latestCreatedRevisionName // empty')
  latest_ready=$(echo "$svc" | jq -r '.status.latestReadyRevisionName // empty')
  route_ready=$(echo "$svc" | jq -r '[.status.conditions[]? | select(.type == "RoutesReady")][0].status // "Unknown"')

  echo "$svc" | jq '{
    name: .metadata.name,
    region: .metadata.labels["cloud.googleapis.com/location"],
    generation: .metadata.generation,
    observedGeneration: .status.observedGeneration,
    latestCreatedRevisionName: .status.latestCreatedRevisionName,
    latestReadyRevisionName: .status.latestReadyRevisionName,
    routesReady: ([.status.conditions[]? | select(.type == "RoutesReady")][0].status // "Unknown"),
    traffic: .status.traffic
  }' >> "$REPORT_FILE"

  # 1. Latest configuration not yet reconciled/rolled out.
  if [ -n "$generation" ] && [ -n "$observed_generation" ] && [ "$generation" != "$observed_generation" ]; then
    add_issue "$ISSUES_FILE" "2" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has not rolled out its latest configuration" \
      "Service \`$name\` in region \`$region\` reports metadata.generation=$generation but observedGeneration=$observed_generation, meaning the latest configuration has not been fully reconciled/applied." \
      "Wait for the rollout to settle or inspect it: gcloud run services describe $name --region=$region --project=$GCP_PROJECT_ID --format=json | jq '.status'. If it never reconciles, check revision build/startup failures." \
      "The latest configuration should be fully rolled out and reconciled" \
      "Configuration generation $generation not reconciled (observed $observed_generation)"
  fi

  # 2. A revision was created but never became Ready (stuck/troubled rollout).
  if [ -n "$latest_created" ] && [ -z "$latest_ready" ]; then
    add_issue "$ISSUES_FILE" "2" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has a troubled rollout (latest revision never Ready)" \
      "Service \`$name\` in region \`$region\` created latest revision \`$latest_created\` but has no Ready revision available to serve traffic (RoutesReady=$route_ready)." \
      "Inspect the failing revision: gcloud run revisions describe $latest_created --region=$region --project=$GCP_PROJECT_ID. Check its conditions and container logs." \
      "A rollout should reach a Ready revision that can serve traffic" \
      "Latest created revision \`$latest_created\` never became Ready"
  fi

  # 3. Rollback / pinned older revision: latest ready revision serves 0% while
  #    some traffic is still routed (rollout reverted to a prior revision).
  if [ -n "$latest_ready" ]; then
    pct=$(echo "$svc" | jq -r --arg rev "$latest_ready" \
      '[.status.traffic[]? | select(.revisionName == $rev)][0].percent // 0')
    traffic_count=$(echo "$svc" | jq '[.status.traffic[]?] | length')
    if [ "$pct" = "0" ] && [ "$traffic_count" -gt 0 ]; then
      serving_percent=$(echo "$svc" | jq -r '[.status.traffic[]? | select(.revisionName != $latest_ready)][0].percent // 0' 2>/dev/null || echo "0")
      add_issue "$ISSUES_FILE" "3" \
        "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has rolled back to a prior revision" \
        "Service \`$name\` in region \`$region\` has latest ready revision \`$latest_ready\` serving 0% of traffic while \`$serving_percent\`% is routed to an older revision -- the rollout was aborted or rolled back." \
        "Decide whether the rollback is intended. To resume the latest rollout: gcloud run services update-traffic $name --region=$region --project=$GCP_PROJECT_ID --to-latest. Inspect why the latest revision cannot serve." \
        "Traffic should be routed to the latest ready revision after a successful rollout" \
        "Latest ready revision \`$latest_ready\` serves 0% while $serving_percent% is pinned to an older revision"
    fi
  fi
done < <(discover_services || echo "")

if [ -s "$REPORT_FILE" ]; then
  jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi

echo "Rollout check complete. Found $(jq length "$ISSUES_FILE") issues."
