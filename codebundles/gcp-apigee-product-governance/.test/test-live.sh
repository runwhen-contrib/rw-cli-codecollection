#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test-live.sh -- the LIVE tier.
#
# Executes each governance check script against the SHARED test org and asserts
# on each script's OWN outputs. Correctness of the check logic is covered by the
# offline tier (offline/run.sh), which needs no credentials; this
# script exists to confirm the scripts behave the same way against real API
# responses.
#
# Requires active gcloud credentials for the org (see terraform/tf.secret).
#
# Exits non-zero if any assertion fails. It keeps going after the first failure
# so one run shows the whole blast radius, and preserves the working directory
# when anything fails.
# -----------------------------------------------------------------------------
set -uo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apigee-live-XXXXXX")"

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${GCP_PROJECT_ID:=${TF_VAR_project_id:-}}"
: "${APIGEE_ORG:?Must set APIGEE_ORG (or TF_VAR_org_id)}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID (or TF_VAR_project_id)}"
APIGEE_ORG="${APIGEE_ORG#organizations/}"
export APIGEE_ORG GCP_PROJECT_ID
export APIPRODUCTS="${APIPRODUCTS:-All}"
export DEVELOPER_APPS="${DEVELOPER_APPS:-All}"
export KEY_EXPIRY_WARNING_DAYS="${KEY_EXPIRY_WARNING_DAYS:-30}"
export USAGE_LOOKBACK_DAYS="${USAGE_LOOKBACK_DAYS:-30}"

# Each script and the files it owns. Validating "the first *_issues.json in the
# directory" would re-check an earlier script's output once several exist, and
# a check that stopped producing anything would still look green.
CASES="
discover_entitlements.sh|entitlements_discovery_issues.json|entitlements_discovery_status.json
check_api_products.sh|api_products_issues.json|api_products_status.json
check_app_credentials.sh|api_credentials_issues.json|api_credentials_status.json
check_orphaned_entitlements.sh|orphaned_entitlements_issues.json|orphaned_entitlements_status.json
check_developer_status.sh|developer_status_issues.json|developer_status_status.json
"

failures=0
note_failure() { echo "    ✗ $1"; failures=$((failures + 1)); }

while IFS='|' read -r script issues_file status_file; do
  [ -z "$script" ] && continue
  echo "==> Running $script"
  case_dir="$WORK_DIR/${script%.sh}"
  mkdir -p "$case_dir"

  ( cd "$case_dir" && bash "$BUNDLE_DIR/$script" ) > "$case_dir/stdout.txt" 2> "$case_dir/stderr.txt"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    note_failure "$script exited $rc (expected 0; check scripts report problems, they do not fail)"
    echo "        stderr: $(head -c 300 "$case_dir/stderr.txt")"
    continue
  fi

  if [ ! -f "$case_dir/$issues_file" ]; then
    note_failure "$script did not produce $issues_file"
    continue
  fi
  if ! jq -e 'type == "array"' "$case_dir/$issues_file" >/dev/null 2>&1; then
    note_failure "$issues_file is not a valid JSON array"
    echo "        head: $(head -c 300 "$case_dir/$issues_file")"
    continue
  fi

  if [ ! -f "$case_dir/$status_file" ]; then
    note_failure "$script did not produce $status_file (the SLI needs it to tell 'clean' from 'could not run')"
    continue
  fi
  access_ok="$(jq -r '.access_ok' "$case_dir/$status_file" 2>/dev/null || echo "unreadable")"
  if [ "$access_ok" != "true" ] && [ "$access_ok" != "false" ]; then
    note_failure "$status_file has no boolean access_ok (got: $access_ok)"
    continue
  fi

  count="$(jq 'length' "$case_dir/$issues_file")"
  if [ "$access_ok" = "true" ]; then
    echo "    ✓ $issues_file: valid array, $count issue(s), access_ok=true"
  else
    # Not an assertion failure by itself -- it is the correct behaviour when the
    # org genuinely cannot be read -- but it means this run proves nothing about
    # the org's health, so say so loudly.
    echo "    ! $issues_file: valid array, $count issue(s), but access_ok=false"
    echo "      reason: $(jq -r '.reason' "$case_dir/$status_file")"
    note_failure "$script could not read the Apigee API; the live run is uninformative"
  fi

  # Every issue must carry the fields the runbook indexes, or Add Issue throws.
  missing="$(jq -r '[.[] | select(
      has("title") and has("details") and has("severity") and
      has("next_steps") and has("expected") and has("actual") | not
    )] | length' "$case_dir/$issues_file")"
  if [ "$missing" != "0" ]; then
    note_failure "$issues_file has $missing issue(s) missing required runbook fields"
  fi
done <<EOF
$(printf '%s\n' "$CASES")
EOF

echo
if [ "$failures" -gt 0 ]; then
  echo "Validation FAILED: $failures assertion(s) failed."
  echo "Artifacts preserved at: $WORK_DIR"
  echo "Each case directory holds stdout.txt, stderr.txt and the JSON outputs."
  exit 1
fi

echo "All checks produced valid, readable output against org $APIGEE_ORG."
if [ "${KEEP_ARTIFACTS:-0}" = "1" ]; then
  echo "Artifacts preserved at: $WORK_DIR"
else
  rm -rf "$WORK_DIR"
fi
