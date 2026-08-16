#!/usr/bin/env bash
set -euo pipefail
# Validates shell syntax for bundle scripts (optional shellcheck when installed).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "Checking scripts under ${ROOT}"
for f in "${ROOT}"/*.sh; do
  [[ -f "$f" ]] || continue
  bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${ROOT}"/*.sh || true
fi
echo "OK: bash syntax check passed for bundle scripts."
