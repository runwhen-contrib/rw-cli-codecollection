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
#
# Auth/permission failures on the instance listing are surfaced as a
# high-severity discovery_failed issue rather than being silently swallowed
# into an empty (falsely healthy) result.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

OUTPUT_FILE="instance_status_issues.json"

echo "Checking Cloud SQL instance status for project: $GCP_PROJECT_ID"

# Fail loud on auth/permission errors: a failed list must raise an issue, not
# return "[]" and look healthy. Only a genuinely empty (successful) list is quiet.
list_stderr=$(mktemp)
if ! instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>"$list_stderr"); then
  gcloud_err=$(cat "$list_stderr"); rm -f "$list_stderr"
  echo "ERROR: unable to list Cloud SQL instances in $GCP_PROJECT_ID: $gcloud_err" >&2
  jq -n --arg proj "$GCP_PROJECT_ID" --arg err "$gcloud_err" '[{
    title: ("Cloud SQL instance discovery failed in project `" + $proj + "`"),
    details: ("Unable to list Cloud SQL instances in project `" + $proj + "`. This usually means the gcp_credentials service account lacks Cloud SQL permissions, or gcloud auth did not activate the intended account. Health results cannot be trusted until this is resolved. gcloud error: " + $err),
    severity: 2,
    expected: "Cloud SQL instances should be discoverable (cloudsql.instances.list permission)",
    actual: "gcloud sql instances list failed",
    next_steps: ("Verify the gcp_credentials secret is the intended service account and that it has roles/cloudsql.viewer (or equivalent) on project " + $proj + ". Confirm gcloud auth activated the correct account."),
    issue_type: "discovery_failed"
  }]' > "$OUTPUT_FILE"
  echo "Discovery failed — raised 1 discovery_failed issue."
  exit 0
fi
rm -f "$list_stderr"

# Genuinely empty project (list succeeded, zero instances) stays quiet.
if [ "$(echo "$instances" | jq 'length')" -eq 0 ]; then
  echo "No Cloud SQL instances found (project has none)."
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
