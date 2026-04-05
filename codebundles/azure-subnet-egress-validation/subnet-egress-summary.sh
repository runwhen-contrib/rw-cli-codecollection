#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Aggregates prior JSON issue files and prints a per-area matrix to stdout.
# Outputs: subnet_egress_summary_issues.json
# -----------------------------------------------------------------------------

OUTPUT_ISSUES="subnet_egress_summary_issues.json"
issues_json='[]'

merge_file() {
  local f="$1"
  if [[ -f "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    issues_json=$(echo "$issues_json" | jq --argjson add "$(cat "$f")" '. + $add')
  fi
}

merge_file "subnet_discover_issues.json"
merge_file "subnet_nsg_issues.json"
merge_file "subnet_route_issues.json"
merge_file "subnet_probe_issues.json"

total=$(echo "$issues_json" | jq 'length')

summary_line() {
  local label="$1"
  local file="$2"
  local n=0
  if [[ -f "$file" ]]; then
    n=$(jq 'length' "$file" 2>/dev/null || echo 0)
  fi
  echo "$label: $n issue(s)"
}

{
  echo "=== Azure Subnet Egress Validation Summary ==="
  summary_line "Discovery" "subnet_discover_issues.json"
  summary_line "NSG egress" "subnet_nsg_issues.json"
  summary_line "Routes / firewall" "subnet_route_issues.json"
  summary_line "Probes" "subnet_probe_issues.json"
  echo "Total combined issues: $total"
  if [[ -f discovered_subnets.json ]]; then
    echo "Subnets in scope: $(jq 'length' discovered_subnets.json)"
  fi
} | tee summary_report.txt

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Summary issues written to $OUTPUT_ISSUES"
