#!/usr/bin/env bash
set -euo pipefail

# Validates the auth0-tenant-health CodeBundle structure and static correctness.
# This runs without network or live credentials; it verifies the files and
# syntax an operator needs for a real Auth0 tenant.

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${BUNDLE_DIR}"

failures=0

check() {
    local name="$1"
    local condition
    shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name}"
        failures=$((failures + 1))
    fi
}

echo "== auth0-tenant-health structure validation =="

# Required files
check "runbook.robot exists" test -f runbook.robot
check "sli.robot exists" test -f sli.robot
check "README.md exists" test -f README.md
check "generation rules exist" test -f .runwhen/generation-rules/auth0-tenant-health.yaml
check "slx template exists" test -f .runwhen/templates/auth0-tenant-health-slx.yaml
check "taskset template exists" test -f .runwhen/templates/auth0-tenant-health-taskset.yaml
check "sli template exists" test -f .runwhen/templates/auth0-tenant-health-sli.yaml

# Bash scripts exist
for script in \
    tenant_availability.sh custom_domain_health.sh analyze_error_logs.sh \
    login_failure_analysis.sh rate_limit_health.sh log_stream_health.sh \
    sli-auth0-tenant-score.sh auth0_helpers.sh; do
    check "bash script ${script} exists" test -f "${script}"
    check "bash script ${script} is executable" test -x "${script}"
    check "bash syntax OK for ${script}" bash -n "${script}"
done

# Scorer-required robot quality checks are surfaced here as a proxy
check "runbook has RW.Core import" grep -q "RW.Core" runbook.robot
check "runbook has RW.CLI import" grep -q "RW.CLI" runbook.robot
check "runbook has Documentation in Settings" grep -q "Documentation" runbook.robot
check "runbook has Force Tags" grep -q "Force Tags" runbook.robot

echo
if [ "${failures}" -eq 0 ]; then
    echo "All structure checks passed."
    exit 0
else
    echo "${failures} structure check(s) failed."
    exit 1
fi