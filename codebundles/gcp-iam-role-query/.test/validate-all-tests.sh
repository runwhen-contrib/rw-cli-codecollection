#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-iam-role-query..."

# Validate all bash scripts parse cleanly.
for script in *.sh; do
  bash -n "$script" || { echo "Syntax error in $script"; exit 1; }
done
echo "All scripts pass syntax validation."

echo "All validation checks passed."
