#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-iam-serviceaccount-health..."

for script in ../check_privileged_roles.sh ../check_key_rotation.sh ../check_key_count.sh ../check_disabled_service_accounts.sh ../analyze_service_account_policy.sh; do
  if [ ! -f "$script" ]; then
    echo "ERROR: Missing script $script"
    exit 1
  fi
  bash -n "$script" || { echo "ERROR: Syntax error in $script"; exit 1; }
done

for exp in ../runbook.robot ../sli.robot ../README.md; do
  if [ ! -f "$exp" ]; then
    echo "ERROR: Missing expected file $exp"
    exit 1
  fi
done

echo "All validation checks passed."
