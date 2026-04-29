#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
need=(
  runbook.robot
  sli.robot
  README.md
  diagnose-vercel-deployments.sh
  report-vercel-project-config.sh
  report-vercel-deployment-branches.sh
  resolve-vercel-deployments-in-window.sh
  collect-vercel-request-logs.sh
  aggregate-vercel-4xx-paths.sh
  aggregate-vercel-5xx-paths.sh
  aggregate-vercel-other-error-paths.sh
  report-vercel-http-error-summary.sh
  probe-vercel-production-urls.sh
  diagnose-recent-failed-deployments.sh
  report-vercel-project-domains.sh
  sli-vercel-api-score.sh
  sli-vercel-deployment-health-score.sh
  sli-vercel-domains-score.sh
  sli-vercel-error-sample-score.sh
  vercel-helpers.sh
  .runwhen/generation-rules/vercel-project-health.yaml
  .runwhen/templates/vercel-project-health-slx.yaml
  .runwhen/templates/vercel-project-health-taskset.yaml
  .runwhen/templates/vercel-project-health-sli.yaml
)
for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done

# Shared Vercel Python lib must resolve via at least one of the two canonical paths
# the bundle scripts add to PYTHONPATH (dev-tree relative or runner-image absolute).
shared_lib_dev="${ROOT}/../../libraries/Vercel/vercel.py"
shared_lib_runner="/home/runwhen/codecollection/libraries/Vercel/vercel.py"
if [[ ! -f "$shared_lib_dev" ]] && [[ ! -f "$shared_lib_runner" ]]; then
  echo "missing shared lib: libraries/Vercel/vercel.py (looked in ${shared_lib_dev} and ${shared_lib_runner})" >&2
  exit 1
fi

echo "vercel-project-health structure OK"
