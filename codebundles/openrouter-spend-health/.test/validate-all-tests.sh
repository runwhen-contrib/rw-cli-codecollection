#!/usr/bin/env bash
set -euo pipefail

echo "Validating OpenRouter Spend Health CodeBundle structure..."

errors=0

check_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: Missing required file: $1"
        errors=$((errors + 1))
    else
        echo "OK: $1"
    fi
}

check_file "../runbook.robot"
check_file "../sli.robot"
check_file "../README.md"
check_file "../.runwhen/generation-rules/openrouter-spend-health.yaml"
check_file "../.runwhen/templates/openrouter-spend-health-slx.yaml"
check_file "../.runwhen/templates/openrouter-spend-health-sli.yaml"
check_file "../.runwhen/templates/openrouter-spend-health-taskset.yaml"

for script in check-openrouter-balance.sh review-openrouter-spend-history.sh analyze-openrouter-spend-by-model.sh check-openrouter-budget.sh forecast-openrouter-spend.sh detect-openrouter-spend-anomalies.sh; do
    check_file "../$script"
done

if [ "$errors" -eq 0 ]; then
    echo "All validation checks passed."
    exit 0
else
    echo "$errors validation error(s) found."
    exit 1
fi