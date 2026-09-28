#!/usr/bin/env bash
# Run mock-based scenario tests without a live Atlassian organization.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${ROOT}/.test/fixtures"
cd "$ROOT"

export ATLASSIAN_ORG_API_KEY="mock-key-not-used"
export ATLASSIAN_DIRECTORY_ID="dir-mock"
export INACTIVE_DAYS_THRESHOLD=90
export PENDING_INVITE_DAYS_THRESHOLD=30
export MIN_OVERLAP_PRODUCTS=2
export RECLAMATION_MIN_SEATS=5
export PRODUCTS=All

run_scenario() {
  local name="$1"
  local inventory="$2"
  local directory_users="${3:-}"
  local expected_min_issues="${4:-0}"

  echo "=== Scenario: ${name} ==="
  rm -f atlassian_user_inventory.json atlassian_directory_users.json \
    atlassian_inactive_billable_issues.json atlassian_product_overlap_issues.json \
    atlassian_pending_invite_issues.json atlassian_reclamation_issues.json \
    atlassian_inactive_billable_data.json atlassian_product_overlap_data.json \
    atlassian_pending_invite_data.json atlassian_license_reclamation_report.md

  export ATLASSIAN_MOCK_INVENTORY="${FIXTURES}/${inventory}"
  if [[ -n "$directory_users" ]]; then
    export ATLASSIAN_MOCK_DIRECTORY_USERS="${FIXTURES}/${directory_users}"
  else
    unset ATLASSIAN_MOCK_DIRECTORY_USERS || true
  fi

  export ATLASSIAN_ORG_ID="test-org"
  export ATLASSIAN_ORG_NAME="Test Org"

  ./identify-atlassian-inactive-billable-users.sh >/dev/null
  ./analyze-atlassian-product-overlap.sh >/dev/null
  ./surface-atlassian-pending-invites.sh >/dev/null
  ./recommend-atlassian-license-reclamation.sh >/dev/null

  local total_issues=0
  for f in atlassian_inactive_billable_issues.json atlassian_product_overlap_issues.json \
           atlassian_pending_invite_issues.json atlassian_reclamation_issues.json; do
    if [[ -f "$f" ]]; then
      local count
      count=$(jq 'length' "$f")
      total_issues=$((total_issues + count))
    fi
  done

  if [[ "$total_issues" -lt "$expected_min_issues" ]]; then
    echo "FAIL: expected at least ${expected_min_issues} issues, got ${total_issues}" >&2
    exit 1
  fi
  echo "PASS: ${total_issues} issue(s) emitted (min expected: ${expected_min_issues})"
}

run_scenario "no_reclamation_candidates" "no_reclamation_inventory.json" "no_reclamation_directory_users.json" 0

# For inactive scenario, use inactive inventory with empty directory (no pending)
export ATLASSIAN_MOCK_DIRECTORY_USERS="${FIXTURES}/no_reclamation_directory_users.json"
run_scenario "inactive_jira_users" "inactive_jira_inventory.json" "no_reclamation_directory_users.json" 1

run_scenario "overlap_and_invites" "overlap_and_invites_inventory.json" "overlap_and_invites_directory_users.json" 2

echo "All mock scenarios passed."
