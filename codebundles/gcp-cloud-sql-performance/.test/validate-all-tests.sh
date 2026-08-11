#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-cloud-sql-performance..."

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. Required robofiles exist
for f in runbook.robot sli.robot README.md; do
  if [ ! -f "$BUNDLE_DIR/$f" ]; then
    echo "FAIL: missing $f"
    exit 1
  fi
done

# 2. Referenced bash scripts exist
for f in discover_sql_instances.sh review_utilization.sh analyze_performance.sh \
         find_long_running_queries.sh check_storage_growth.sh; do
  if [ ! -f "$BUNDLE_DIR/$f" ]; then
    echo "FAIL: missing script $f"
    exit 1
  fi
done

# 3. Generation rules includes sli output item + templates exist
if [ ! -f "$BUNDLE_DIR/.runwhen/generation-rules/gcp-cloud-sql-performance.yaml" ]; then
  echo "FAIL: missing generation rules"
  exit 1
fi
for f in gcp-cloud-sql-performance-slx.yaml gcp-cloud-sql-performance-taskset.yaml gcp-cloud-sql-performance-sli.yaml; do
  if [ ! -f "$BUNDLE_DIR/.runwhen/templates/$f" ]; then
    echo "FAIL: missing template $f"
    exit 1
  fi
done

# 4. Scripts are valid bash
for f in "$BUNDLE_DIR"/*.sh; do
  bash -n "$f"
done

echo "All validation checks passed."
