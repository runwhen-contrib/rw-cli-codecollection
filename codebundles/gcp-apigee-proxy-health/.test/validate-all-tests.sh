#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-apigee-proxy-health..."

for f in ../*.sh; do
  bash -n "$f" || { echo "Syntax error in $f"; exit 1; }
done

echo "All validation checks passed."
