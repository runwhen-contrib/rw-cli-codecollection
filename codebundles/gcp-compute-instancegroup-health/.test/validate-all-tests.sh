#!/usr/bin/env bash
# Validate the generation rules and template files for this codebundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_NAME="gcp-compute-instancegroup-health"

echo "Validating generation rules: $BUNDLE_NAME"
for f in "$ROOT"/.runwhen/generation-rules/*.yaml; do
  echo "  Checking $f"
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$f" >/dev/null || { echo "  Invalid YAML in $f"; exit 1; }
  fi
done

echo "Validating templates: $BUNDLE_NAME"
for f in "$ROOT"/.runwhen/templates/*.yaml; do
  echo "  Checking $f"
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$f" >/dev/null || { echo "  Invalid YAML in $f"; exit 1; }
  fi
done

echo "Checking bash scripts are present."
for s in discover_instance_groups.sh check_group_member_health.sh check_autoscaling.sh \
         check_group_patch_status.sh check_group_utilization.sh generate_group_summary.sh; do
  if [ ! -f "$ROOT/$s" ]; then
    echo "  Missing script: $s"
    exit 1
  fi
done

echo "All validations passed for $BUNDLE_NAME."
