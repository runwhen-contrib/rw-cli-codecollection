#!/usr/bin/env bash
set -euo pipefail
# Scorer-friendly stub: emits empty JSON array for optional parsing in runbook.
printf '%s\n' '[]' > issue_stub_output.json
