#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate-all-tests.sh
#
# Executes each governance check script against the SHARED test org and
# validates that every one emits a well-formed JSON issues array. This is the
# smoke test that confirms the scripts run end-to-end and produce parseable
# output for the runbook.
#
# Requires active gcloud credentials for the org (see terraform/tf.secret).
# Set APIPRODUCTS/DEVELOPER_APPS/KEY_EXPIRY_WARNING_DAYS/USAGE_LOOKBACK_DAYS
# as needed; defaults mirror the runbook defaults.
# -----------------------------------------------------------------------------
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
export APIPRODUCTS="${APIPRODUCTS:-All}"
export DEVELOPER_APPS="${DEVELOPER_APPS:-All}"
export KEY_EXPIRY_WARNING_DAYS="${KEY_EXPIRY_WARNING_DAYS:-30}"
export USAGE_LOOKBACK_DAYS="${USAGE_LOOKBACK_DAYS:-30}"

scripts=(
  discover_entitlements.sh
  check_api_products.sh
  check_app_credentials.sh
  check_orphaned_entitlements.sh
  check_developer_status.sh
)

failures=0
for script in "${scripts[@]}"; do
  echo "==> Running $script"
  ( cd "$WORK_DIR" && bash "$BUNDLE_DIR/$script" >/dev/null 2>&1 )
  # Each script writes exactly one *issues.json corresponding to its own check.
  issues_file="$(cd "$WORK_DIR" && ls -1 *_issues.json 2>/dev/null | head -n1 || true)"
  if [ -z "$issues_file" ]; then
    echo "    ✗ no issues file produced by $script"
    failures=$((failures + 1))
    continue
  fi
  if ! ( cd "$WORK_DIR" && jq -e '. | type == "array"' "$issues_file" >/dev/null 2>&1 ); then
    echo "    ✗ $issues_file is not a valid JSON array"
    failures=$((failures + 1))
    continue
  fi
  count="$(cd "$WORK_DIR" && jq 'length' "$issues_file")"
  echo "    ✓ $issues_file is valid JSON array with $count issue(s)"
done

if [ "$failures" -gt 0 ]; then
  echo "Validation FAILED: $failures script(s) produced invalid output."
  exit 1
fi

echo "All checks produced valid JSON output."
