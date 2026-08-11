#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-project-configuration-audit..."

# Validate all referenced bash scripts are present
for script in analyze_permission_denied.sh detect_iam_policy_changes.sh \
              analyze_org_policy_violations.sh check_audit_log_config.sh \
              generate_audit_summary.sh; do
  if [ ! -f "../$script" ]; then
    echo "✗ Missing script: $script"
    exit 1
  fi
done

# Validate shell syntax of all scripts
for script in *.sh ../analyze_permission_denied.sh ../detect_iam_policy_changes.sh \
              ../analyze_org_policy_violations.sh ../check_audit_log_config.sh \
              ../generate_audit_summary.sh; do
  bash -n "$script" || { echo "✗ Syntax error in $script"; exit 1; }
done

echo "All validation checks passed."
