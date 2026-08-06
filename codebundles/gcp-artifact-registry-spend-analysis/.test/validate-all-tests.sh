#!/usr/bin/env bash
# Static validation for gcp-artifact-registry-spend-analysis (no live GCP required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/.runwhen/generation-rules/gcp-artifact-registry-spend-analysis.yaml"
test -f "$ROOT/.runwhen/templates/gcp-artifact-registry-spend-analysis-slx.yaml"
test -f "$ROOT/.runwhen/templates/gcp-artifact-registry-spend-analysis-taskset.yaml"
test -f "$ROOT/.runwhen/templates/gcp-artifact-registry-spend-analysis-sli.yaml"
for f in \
  artifact-billing-helpers.sh \
  analyze-artifact-registry-spend.sh \
  report-top-artifact-cost-contributors.sh \
  compare-artifact-spend-mom.sh \
  detect-artifact-cost-anomalies.sh \
  generate-artifact-spend-recommendations.sh \
  sli-artifact-spend-health-score.sh
do
  test -f "$ROOT/$f"
done
grep -q 'severity' "$ROOT/analyze-artifact-registry-spend.sh"
grep -q 'next_steps' "$ROOT/detect-artifact-cost-anomalies.sh"
grep -q 'RW.Core.Add Issue' "$ROOT/runbook.robot"
grep -q 'RW.Core.Push Metric' "$ROOT/sli.robot"
grep -q 'type: sli' "$ROOT/.runwhen/generation-rules/gcp-artifact-registry-spend-analysis.yaml"
echo "gcp-artifact-registry-spend-analysis bundle structure OK"
