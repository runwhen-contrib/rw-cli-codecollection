#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
need=(
  runbook.robot
  sli.robot
  README.md
  vercel-http-lib.sh
  resolve-vercel-deployments-in-window.sh
  aggregate-vercel-404-paths.sh
  aggregate-vercel-5xx-paths.sh
  aggregate-vercel-other-error-paths.sh
  report-vercel-http-error-summary.sh
  sli-vercel-api-score.sh
  sli-vercel-error-sample-score.sh
  .runwhen/generation-rules/vercel-project-http-errors.yaml
  .runwhen/templates/vercel-project-http-errors-slx.yaml
  .runwhen/templates/vercel-project-http-errors-taskset.yaml
  .runwhen/templates/vercel-project-http-errors-sli.yaml
)
for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done
echo "vercel-project-http-errors structure OK"
