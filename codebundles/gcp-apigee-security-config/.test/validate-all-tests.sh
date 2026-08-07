#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-apigee-security-config..."

for script in ../check_keystore_tls.sh ../check_quota_limits.sh ../check_app_access.sh ../check_security_score.sh ../check_target_vhost_config.sh ../generate_security_summary.sh ../sli.robot ../runbook.robot; do
  if [ ! -f "$script" ]; then
    echo "Error: $script not found."
    exit 1
  fi
done

echo "All validation checks passed."
