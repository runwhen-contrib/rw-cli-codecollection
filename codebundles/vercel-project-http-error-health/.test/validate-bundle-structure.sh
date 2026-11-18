#!/usr/bin/env bash
# Sanity check that required CodeBundle files exist (local dev / CI helper).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/sli.robot"
test -f "$ROOT/.runwhen/generation-rules/vercel-project-http-error-health.yaml"
test -f "$ROOT/.runwhen/templates/vercel-project-http-error-health-slx.yaml"
test -f "$ROOT/.runwhen/templates/vercel-project-http-error-health-taskset.yaml"
test -f "$ROOT/.runwhen/templates/vercel-project-http-error-health-sli.yaml"
echo "vercel-project-http-error-health bundle structure OK"
