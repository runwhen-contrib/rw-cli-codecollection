#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helpers for gcp-cloudrun-service-health.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES       - Comma-separated Cloud Run service names to check, or 'All'
#                     to auto-discover every service in the project. Default: All.
#
# This file is sourced by each task script so all tasks iterate the exact same
# set of Cloud Run services and share a single JSON issue-append helper.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"

# Emit one JSON object per Cloud Run service (one per line) to stdout.
# If RESOURCES is a comma-separated list of service names, output is restricted
# to those services; otherwise every service in the project is emitted.
discover_services() {
  local services_json
  services_json=$(gcloud run services list \
    --platform=managed \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>/dev/null || echo "[]")

  if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
    services_json=$(echo "$services_json" | jq --arg names "$RESOURCES" '
      map(select(
        (.metadata.name as $n |
          ($names | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | index($n)))
      ))
    ')
  fi

  echo "$services_json" | jq -c '.[]'
}

# Echo the Ready condition status ("True"/"False"/"Unknown") of a single revision.
#
# Needed because Cloud Run pins `status.latestReadyRevisionName` to the revision
# that is actually routed traffic. A newer revision that is Ready but receives 0%
# of traffic shows up only as `status.latestCreatedRevisionName`, so callers that
# want to reason about the newest revision must look it up directly.
# Echoes "Lookup-Failed" (never a bare failure) when the revision cannot be read,
# so callers can tell "this revision is broken" apart from "we could not check",
# and so a failed lookup does not abort a caller running under `set -e`.
# Usage: revision_ready <revision_name> <region>
revision_ready() {
  local revision="$1"
  local region="$2"
  local json status

  json=$(gcloud run revisions describe "$revision" \
    --region="$region" \
    --platform=managed \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>/dev/null) || { echo "Lookup-Failed"; return 0; }

  status=$(echo "$json" | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown"' 2>/dev/null)
  echo "${status:-Lookup-Failed}"
}

# Append an issue object to a JSON array file.
# Usage: add_issue <file> <severity> <title> <details> <next_steps> <expected> <actual>
add_issue() {
  local file="$1"
  local severity="$2"
  local title="$3"
  local details="$4"
  local next_steps="$5"
  local expected="$6"
  local actual="$7"

  if [ ! -f "$file" ]; then
    echo "[]" > "$file"
  fi

  jq --arg title "$title" \
     --arg details "$details" \
     --arg sev "$severity" \
     --arg next "$next_steps" \
     --arg exp "$expected" \
     --arg act "$actual" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($sev | tonumber),
      "next_steps": $next,
      "expected": $exp,
      "actual": $act
    }]' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
