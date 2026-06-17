#!/usr/bin/env bash
# Validates required CodeBundle files for gcp-dms-migration-health (CI / local).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/.runwhen/generation-rules/gcp-dms-migration-health.yaml"
test -f "$ROOT/.runwhen/templates/gcp-dms-migration-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/gcp-dms-migration-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/gcp-dms-migration-health-sli.yaml"
echo "gcp-dms-migration-health bundle structure OK"
