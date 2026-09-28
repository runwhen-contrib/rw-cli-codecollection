#!/usr/bin/env bash
# Static validation for atlassian-org-license-utilization (no live Atlassian org required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/.runwhen/generation-rules/atlassian-org-license-utilization.yaml"
test -f "$ROOT/.runwhen/templates/atlassian-org-license-utilization-slx.yaml"
test -f "$ROOT/.runwhen/templates/atlassian-org-license-utilization-taskset.yaml"
test -f "$ROOT/.runwhen/templates/atlassian-org-license-utilization-sli.yaml"
for f in \
  atlassian-api-helpers.sh \
  generate-atlassian-license-utilization-report.sh \
  analyze-atlassian-tier-proximity.sh \
  evaluate-atlassian-utilization-thresholds.sh \
  report-atlassian-active-user-trends.sh \
  sli-atlassian-org-license-score.sh
do
  test -f "$ROOT/$f"
done
echo "atlassian-org-license-utilization bundle structure OK"
