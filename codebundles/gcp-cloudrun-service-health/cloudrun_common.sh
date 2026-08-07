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
