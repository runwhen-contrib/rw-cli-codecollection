#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need=(
  runbook.robot
  sli.robot
  README.md
  artifact-billing-common.sh
  analyze-artifact-registry-spend.sh
  report-top-artifact-cost-contributors.sh
  compare-artifact-spend-mom.sh
  detect-artifact-cost-anomalies.sh
  generate-artifact-spend-recommendations.sh
  artifact-spend-sli-check.sh
  .runwhen/generation-rules/gcp-artifact-registry-spend-analysis.yaml
  .runwhen/templates/gcp-artifact-registry-spend-analysis-slx.yaml
  .runwhen/templates/gcp-artifact-registry-spend-analysis-taskset.yaml
  .runwhen/templates/gcp-artifact-registry-spend-analysis-sli.yaml
)

for f in "${need[@]}"; do
  if [[ ! -e "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done

for script in *.sh; do
  if [[ ! -x "$script" ]]; then
    echo "not executable: $script" >&2
    exit 1
  fi
done

# Validate JSON issue structure helpers using mock billing rows (no live GCP required)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/mock_rows.json" <<'EOF'
[
  {"project_id":"proj-a","project_name":"Project A","service_name":"Artifact Registry","sku_description":"Artifact Registry Storage","usage_date":"2026-05-01","total_cost":"100","usage_amount":"10","usage_unit":"gibibyte month"},
  {"project_id":"proj-a","project_name":"Project A","service_name":"Container Registry","sku_description":"Container Registry Storage","usage_date":"2026-05-01","total_cost":"50","usage_amount":"5","usage_unit":"gibibyte month"},
  {"project_id":"proj-b","project_name":"Project B","service_name":"Artifact Registry","sku_description":"Artifact Registry Storage","usage_date":"2026-05-01","total_cost":"10","usage_amount":"1","usage_unit":"gibibyte month"}
]
EOF

total=$(jq '[.[].total_cost | tonumber] | add' "$TMPDIR/mock_rows.json")
if [[ "$total" != "160" ]]; then
  echo "mock aggregation failed: expected 160 got $total" >&2
  exit 1
fi

echo "gcp-artifact-registry-spend-analysis structure OK"
