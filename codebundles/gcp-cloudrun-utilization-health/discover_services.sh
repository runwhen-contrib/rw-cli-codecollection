#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Cloud Run services in a GCP project.
#
# Auto-discovers all Cloud Run services via `gcloud run services list`, then
# (optionally) restricts the set to the comma-separated RESOURCES list. Writes a
# normalized catalog to DISCOVERY_FILE that other checks source/read.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project ID hosting the Cloud Run services
#   RESOURCES        - Comma-separated service names to check, or "All" for
#                      auto-discovery (default All)
#
# OUTPUTS:
#   cloudrun_services.json - Normalized array of {name, region, url, maxScale,
#                            minScale, containerConcurrency, cpu, memory}
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

DISCOVERY_FILE="${DISCOVERY_FILE:-cloudrun_services.json}"

echo "Discovering Cloud Run services in project: $GCP_PROJECT_ID (RESOURCES=$RESOURCES)"

services=$(gcloud run services list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

if [ "$RESOURCES" != "All" ]; then
  echo "Restricting discovery to RESOURCES subset: $RESOURCES"
  services=$(echo "$services" | jq --arg filter "$RESOURCES" '
    [.[] | select(
      (.metadata.name) as $nameb |
      (($filter | split(",") | map(strip) | map(select(length > 0)))) as $names |
      any($names[]; $nameb == .)
    )]')
fi

echo "$services" | jq '
  [.[] |
    {
      name: .metadata.name,
      region: (.metadata.labels["cloud.googleapis.com/location"] // ""),
      url: (.status.url // ""),
      maxScale: (.spec.template.metadata.annotations["autoscaling.knative.dev/maxScale"] // ""),
      minScale: (.spec.template.metadata.annotations["autoscaling.knative.dev/minScale"] // ""),
      containerConcurrency: (.spec.template.spec.containerConcurrency // 0),
      cpu: (.spec.template.spec.containers[0].resources.limits.cpu // ""),
      memory: (.spec.template.spec.containers[0].resources.limits.memory // "")
    }
  ]' > "$DISCOVERY_FILE"

echo "Discovered $(jq length "$DISCOVERY_FILE") Cloud Run service(s)."
