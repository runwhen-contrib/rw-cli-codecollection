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
# NDJSON scratch file: one object per line, slurped into a JSON array at the end.
# Seeding REPORT_FILE itself with "[]" would leave a stray empty array as the
# first element after the slurp.
REPORT_LINES="${REPORT_FILE}.ndjson"
: > "$REPORT_LINES"

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
  }' >> "$REPORT_LINES"

  # 1. Latest configuration not yet reconciled/rolled out.
  if [ -n "$generation" ] && [ -n "$observed_generation" ] && [ "$generation" != "$observed_generation" ]; then
    add_issue "$ISSUES_FILE" "2" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has not rolled out its latest configuration" \
      "Service \`$name\` in region \`$region\` reports metadata.generation=$generation but observedGeneration=$observed_generation, meaning the latest configuration has not been fully reconciled/applied." \
      "Wait for the rollout to settle or inspect it: gcloud run services describe $name --region=$region --project=$GCP_PROJECT_ID --format=json | jq '.status'. If it never reconciles, check revision build/startup failures." \
      "The latest configuration should be fully rolled out and reconciled" \
      "Configuration generation $generation not reconciled (observed $observed_generation)"
  fi

  # 2/3. The newest revision is not the one serving traffic.
  #
  # Cloud Run pins `latestReadyRevisionName` to the revision that is actually
  # routed traffic, so comparing it against `latestCreatedRevisionName` -- not
  # testing it for emptiness -- is what identifies a rollout that did not land.
  # Two distinct outcomes follow, so the newest revision's Ready state decides
  # which issue is raised:
  #   - newest revision never became Ready  -> troubled/stuck rollout (Sev 2)
  #   - newest revision is Ready but unrouted -> aborted / rolled back (Sev 3)
  # "Lookup-Failed" means the revision could not be read at all; stay silent
  # rather than report a rollout problem we have not actually observed.
  if [ -n "$latest_created" ] && [ "$latest_created" != "$latest_ready" ]; then
    latest_created_ready=$(revision_ready "$latest_created" "$region")

    if [ "$latest_created_ready" = "Lookup-Failed" ]; then
      echo "WARNING: could not read revision $latest_created of service $name; skipping rollout assessment." >&2
    elif [ "$latest_created_ready" != "True" ]; then
      add_issue "$ISSUES_FILE" "2" \
        "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has a troubled rollout (latest revision never Ready)" \
        "Service \`$name\` in region \`$region\` created latest revision \`$latest_created\` (Ready=$latest_created_ready) but traffic is still served by \`${latest_ready:-no ready revision}\` (RoutesReady=$route_ready)." \
        "Inspect the failing revision: gcloud run revisions describe $latest_created --region=$region --project=$GCP_PROJECT_ID. Check its conditions and container logs." \
        "A rollout should reach a Ready revision that can serve traffic" \
        "Latest created revision \`$latest_created\` never became Ready"
    else
      pct=$(echo "$svc" | jq -r --arg rev "$latest_created" \
        '[.status.traffic[]? | select(.revisionName == $rev)][0].percent // 0')
      if [ "$pct" = "0" ]; then
        serving_revision=$(echo "$svc" | jq -r --arg rev "$latest_created" \
          '[.status.traffic[]? | select(.revisionName != $rev and (.percent // 0) > 0)][0].revisionName // "unknown"')
        serving_percent=$(echo "$svc" | jq -r --arg rev "$latest_created" \
          '[.status.traffic[]? | select(.revisionName != $rev and (.percent // 0) > 0)][0].percent // 0')
        add_issue "$ISSUES_FILE" "3" \
          "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has rolled back to a prior revision" \
          "Service \`$name\` in region \`$region\` has newest Ready revision \`$latest_created\` serving 0% of traffic while $serving_percent% is routed to the older revision \`$serving_revision\` -- the rollout was aborted or rolled back." \
          "Decide whether the rollback is intended. To resume the latest rollout: gcloud run services update-traffic $name --region=$region --project=$GCP_PROJECT_ID --to-latest. Inspect why the latest revision cannot serve." \
          "Traffic should be routed to the latest ready revision after a successful rollout" \
          "Newest Ready revision \`$latest_created\` serves 0% while $serving_percent% is pinned to \`$serving_revision\`"
      fi
    fi
  fi
done < <(discover_services || echo "")

if [ -s "$REPORT_LINES" ]; then
  jq -s '.' "$REPORT_LINES" > "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi
rm -f "$REPORT_LINES"

echo "Rollout check complete. Found $(jq length "$ISSUES_FILE") issues."
