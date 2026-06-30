#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
need=(
  runbook.robot
  sli.robot
  README.md
  gcp-artifact-registry-helpers.sh
  discover-artifact-repositories.sh
  check-cleanup-policies.sh
  identify-stale-images.sh
  identify-untagged-images.sh
  detect-legacy-gcr-usage.sh
  report-repository-storage-utilization.sh
  generate-cleanup-policy-recommendations.sh
  .runwhen/generation-rules/gcp-artifact-registry-governance.yaml
  .runwhen/templates/gcp-artifact-registry-governance-slx.yaml
  .runwhen/templates/gcp-artifact-registry-governance-taskset.yaml
  .runwhen/templates/gcp-artifact-registry-governance-sli.yaml
)
for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done
echo "gcp-artifact-registry-governance structure OK"
