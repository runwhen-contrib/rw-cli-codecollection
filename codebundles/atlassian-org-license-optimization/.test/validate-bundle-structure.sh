#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

need=(
  runbook.robot
  sli.robot
  README.md
  atlassian-api-helpers.sh
  identify-atlassian-inactive-billable-users.sh
  analyze-atlassian-product-overlap.sh
  surface-atlassian-pending-invites.sh
  recommend-atlassian-license-reclamation.sh
  sli-atlassian-license-reclamation-health.sh
  .runwhen/generation-rules/atlassian-org-license-optimization.yaml
  .runwhen/templates/atlassian-org-license-optimization-slx.yaml
  .runwhen/templates/atlassian-org-license-optimization-taskset.yaml
  .runwhen/templates/atlassian-org-license-optimization-sli.yaml
)

for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done

for f in *.sh; do
  if [[ ! -x "$f" ]]; then
    echo "not executable: $f" >&2
    exit 1
  fi
done

echo "atlassian-org-license-optimization bundle structure OK"
