#!/usr/bin/env bash
# Static validation for cloudflare-zone-waf-report (no live Cloudflare credentials required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/.runwhen/generation-rules/cloudflare-zone-waf-report.yaml"
test -f "$ROOT/.runwhen/templates/cloudflare-zone-waf-report-slx.yaml"
test -f "$ROOT/.runwhen/templates/cloudflare-zone-waf-report-taskset.yaml"
test -f "$ROOT/.runwhen/templates/cloudflare-zone-waf-report-sli.yaml"
for f in \
  fetch-cloudflare-firewall-events.sh \
  aggregate-waf-by-rule.sh \
  correlate-waf-by-source.sh \
  aggregate-waf-by-path.sh \
  evaluate-waf-thresholds.sh \
  report-waf-correlation-summary.sh \
  sli-cloudflare-waf-score.sh
do
  test -x "$ROOT/$f"
done
echo "cloudflare-zone-waf-report bundle structure OK"
