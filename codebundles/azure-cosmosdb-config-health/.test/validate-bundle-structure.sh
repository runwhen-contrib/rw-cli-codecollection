#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
need() {
  if [[ ! -e "$1" ]]; then
    echo "missing: $1" >&2
    fail=1
  fi
}
need runbook.robot
need sli.robot
need README.md
need .runwhen/generation-rules/azure-cosmosdb-config-health.yaml
need .runwhen/templates/azure-cosmosdb-config-health-slx.yaml
need .runwhen/templates/azure-cosmosdb-config-health-taskset.yaml
need .runwhen/templates/azure-cosmosdb-config-health-sli.yaml
for s in cosmosdb-resource-health.sh cosmosdb-api-consistency-config.sh cosmosdb-backup-policy.sh \
  cosmosdb-network-firewall.sh cosmosdb-private-endpoints.sh cosmosdb-diagnostic-settings.sh \
  cosmosdb-activity-changes.sh cosmosdb-sli-dimensions.sh cosmosdb_common.sh; do
  need "$s"
done
exit "$fail"
