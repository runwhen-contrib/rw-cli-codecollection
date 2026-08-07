#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-cloudspanner-query-performance..."
for f in ../*.sh; do
  echo "bash -n $f"
  bash -n "$f"
done
echo "All validation checks passed."
