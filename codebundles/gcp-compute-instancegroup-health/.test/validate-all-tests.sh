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
# The templates are Jinja and only become YAML once the workspace builder
# renders them, so feeding them straight to yq fails on '{% include %}'. They
# are rendered here with every variable undefined and every include empty,
# which is enough to prove the surrounding document is well-formed YAML.
if python3 -c "import jinja2, yaml" 2>/dev/null; then
  for f in "$ROOT"/.runwhen/templates/*.yaml; do
    echo "  Checking $f"
    python3 - "$f" <<'PY' || { echo "  Invalid template: $f"; exit 1; }
import sys
import yaml
from jinja2 import BaseLoader, ChainableUndefined, Environment


class EmptyLoader(BaseLoader):
    """Resolve every {% include %} to an empty string."""

    def get_source(self, environment, template):
        return "", template, lambda: True


env = Environment(loader=EmptyLoader(), undefined=ChainableUndefined)
with open(sys.argv[1]) as handle:
    yaml.safe_load(env.from_string(handle.read()).render())
PY
  done
else
  echo "  Skipping: python3 with jinja2 and pyyaml is required to render templates."
fi

echo "Checking bash scripts are present."
for s in check_group_member_health.sh check_autoscaling.sh \
         check_group_patch_status.sh check_group_utilization.sh; do
  if [ ! -f "$ROOT/$s" ]; then
    echo "  Missing script: $s"
    exit 1
  fi
done

echo "All validations passed for $BUNDLE_NAME."
