#!/usr/bin/env bash
# Lightweight sanity check that generation rules and templates exist (for CI or local dev).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/runbook.robot"
test -f "$ROOT/.runwhen/generation-rules/k8s-statefulset-ops.yaml"
test -f "$ROOT/.runwhen/templates/k8s-statefulset-ops-slx.yaml"
test -f "$ROOT/.runwhen/templates/k8s-statefulset-ops-taskset.yaml"
echo "k8s-statefulset-ops bundle structure OK"
