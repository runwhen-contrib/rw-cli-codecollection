#!/usr/bin/env bash
# Validate all test scenarios for gcp-bigquery-job-health
set -euo pipefail

echo "=== Validating gcp-bigquery-job-health Test Scenarios ==="

# Check that all required scripts exist
for script in check_job_success_rate.sh analyze_failed_jobs.sh identify_slow_jobs.sh check_slot_contention.sh generate_job_summary.sh; do
    if [ -f "../$script" ]; then
        echo "PASS: $script exists"
    else
        echo "FAIL: $script is missing"
        exit 1
    fi
done

# Check runbook.robot exists
if [ -f "../runbook.robot" ]; then
    echo "PASS: runbook.robot exists"
else
    echo "FAIL: runbook.robot is missing"
    exit 1
fi

# Check sli.robot exists
if [ -f "../sli.robot" ]; then
    echo "PASS: sli.robot exists"
else
    echo "FAIL: sli.robot is missing"
    exit 1
fi

# Check README exists
if [ -f "../README.md" ]; then
    echo "PASS: README.md exists"
else
    echo "FAIL: README.md is missing"
    exit 1
fi

echo ""
echo "=== All validation checks passed ==="