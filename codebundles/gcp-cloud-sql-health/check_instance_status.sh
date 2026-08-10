#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   RESOURCES  (comma-separated instance name filter; "All" to check everything)
#
# This script enumerates Cloud SQL instances in the project and flags any
# instance whose state is not RUNNABLE (maintenance, failed, suspended, etc.).
# It writes a JSON array of issues to instance_status_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

OUTPUT_FILE="instance_status_issues.json"

echo "Checking Cloud SQL instance status for project: $GCP_PROJECT_ID"

instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No Cloud SQL instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
  filter=$(echo "$RESOURCES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | paste -sd'|' -)
  if [ -z "$filter" ]; then
    filter="NEVER_MATCHES"
  fi
  instances=$(echo "$instances" | jq --arg f "$filter" '[.[] | select(.name | test($f))]')
  echo "Filtered to requested instances matching: $RESOURCES"
fi

if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No matching instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  name=$(echo "$inst" | jq -r '.name // "unknown"')
  state=$(echo "$inst" | jq -r '.state // "UNKNOWN"')

  if [ "$state" != "RUNNABLE" ]; then
    printf '{"title":"Cloud SQL instance `%s` is not RUNNABLE","details":"Cloud SQL instance `%s` in project `%s` has state `%s`. Expected state is RUNNABLE.","severity":3,"expected":"Instance state should be RUNNABLE","actual":"Instance state is %s","next_steps":"Inspect the instance for pending maintenance, migration, or suspension. Review operations with: gcloud sql operations list --instance=%s --project=%s. Restart or resume the instance as needed.","instance":"%s","state":"%s","issue_type":"instance_not_runnable"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$state" "$state" "$name" "$GCP_PROJECT_ID" "$name" "$state" >> "$OUTPUT_FILE"
  else
    echo "  Instance $name is RUNNABLE."
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Status check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
