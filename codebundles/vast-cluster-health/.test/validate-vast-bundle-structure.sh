#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need=(
  runbook.robot
  sli.robot
  README.md
  vast-vms-common.sh
  check-vms-cluster-health.sh
  check-cluster-capacity.sh
  check-node-hardware-health.sh
  check-degraded-components.sh
  analyze-cluster-performance.sh
  check-replication-status.sh
  sli-vast-cluster-health-score.sh
  .runwhen/generation-rules/vast-cluster-health.yaml
  .runwhen/templates/vast-cluster-health-slx.yaml
  .runwhen/templates/vast-cluster-health-taskset.yaml
  .runwhen/templates/vast-cluster-health-sli.yaml
)

for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done

echo "vast-cluster-health structure OK"
