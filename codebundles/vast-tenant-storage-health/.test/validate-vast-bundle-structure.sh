#!/usr/bin/env bash
# Static validation for vast-tenant-storage-health.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/vast-vms-helpers.sh"
test -f "$ROOT/.runwhen/generation-rules/vast-tenant-storage-health.yaml"
test -f "$ROOT/.runwhen/templates/vast-tenant-storage-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/vast-tenant-storage-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/vast-tenant-storage-health-sli.yaml"

for f in \
  discover-vast-tenants.sh \
  check-tenant-capacity.sh \
  check-view-capacity.sh \
  analyze-tenant-qos.sh \
  check-qos-wait-times.sh \
  check-tenant-config.sh \
  analyze-tenant-latency.sh \
  check-block-volume-health.sh \
  sli-vast-capacity-score.sh \
  sli-vast-qos-score.sh \
  sli-vast-latency-score.sh
do
  test -f "$ROOT/$f"
done

echo "vast-tenant-storage-health bundle structure OK"
