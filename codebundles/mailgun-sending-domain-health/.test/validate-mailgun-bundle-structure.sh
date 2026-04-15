#!/usr/bin/env bash
# Static validation for mailgun-sending-domain-health (no live Mailgun account required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/README.md"
test -f "$ROOT/.runwhen/generation-rules/mailgun-sending-domain-health.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-sending-domain-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-sending-domain-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-sending-domain-health-sli.yaml"
for f in \
  discover-mailgun-domains.sh \
  check-mailgun-domain-state.sh \
  check-mailgun-delivery-success-rate.sh \
  check-mailgun-bounce-complaint-rates.sh \
  check-mailgun-recent-failures.sh \
  verify-mailgun-spf-dns.sh \
  verify-mailgun-dkim-dns.sh \
  verify-mailgun-dmarc-dns.sh \
  verify-mailgun-mx-dns.sh \
  sli-mailgun-domain-score.sh \
  sli-mailgun-delivery-score.sh \
  sli-mailgun-spf-score.sh
do
  test -x "$ROOT/$f"
done
echo "mailgun-sending-domain-health bundle structure OK"
