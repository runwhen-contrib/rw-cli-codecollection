#!/usr/bin/env bash
# Sanity check for Mailgun platform bundle layout (no cloud resources required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/.runwhen/generation-rules/mailgun-platform-status-health.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-platform-status-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-platform-status-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/mailgun-platform-status-health-sli.yaml"
echo "mailgun-platform-status-health bundle structure OK"
