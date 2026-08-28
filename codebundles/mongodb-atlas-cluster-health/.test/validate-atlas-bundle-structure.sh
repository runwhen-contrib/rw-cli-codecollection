#!/usr/bin/env bash
# Structure validation for mongodb-atlas-cluster-health (no live Atlas project required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/.runwhen/generation-rules/mongodb-atlas-cluster-health.yaml"
test -f "$ROOT/.runwhen/templates/mongodb-atlas-cluster-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/mongodb-atlas-cluster-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/mongodb-atlas-cluster-health-sli.yaml"

for f in \
  gather-atlas-cluster-inventory.sh \
  check-atlas-cluster-state.sh \
  analyze-atlas-cluster-metrics.sh \
  sli-mongodb-atlas-quick-check.sh \
  atlas-api-common.inc.sh
do
  test -x "$ROOT/$f"
done

echo "mongodb-atlas-cluster-health bundle structure OK"
