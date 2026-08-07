#!/usr/bin/env bash
set -euo pipefail

echo "Validating tests for gcp-cloud-composer-performance..."

# Validate the scripts are syntactically valid bash.
for script in ../composer_metrics_common.sh \
              ../discover_composer_environments.sh \
              ../analyze_worker_utilization.sh \
              ../analyze_scheduler_and_queues.sh \
              ../detect_overprovisioning.sh \
              ../detect_usage_deltas.sh \
              ../compute_composer_sli.sh; do
    if [ ! -f "$script" ]; then
        echo "✗ Missing script: $script"
        exit 1
    fi
    if bash -n "$script"; then
        echo "√ Bash syntax OK: $script"
    else
        echo "✗ Bash syntax error in $script"
        exit 1
    fi
done

# Validate generation rules and templates are well-formed YAML.
for yaml_file in ../.runwhen/generation-rules/*.yaml ../.runwhen/templates/*.yaml; do
    if python3 -c "import sys, yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
        echo "√ YAML OK: $yaml_file"
    else
        echo "✗ Invalid YAML: $yaml_file"
        exit 1
    fi
done

echo "All validation checks passed."
