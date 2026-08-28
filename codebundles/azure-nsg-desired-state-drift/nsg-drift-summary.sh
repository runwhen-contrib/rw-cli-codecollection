#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Aggregates drift from nsg_diff_issues.json and nsg_assoc_issues.json;
# writes nsg_summary_issues.json and prints operator summary (stdout).
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
OUT_ISSUES="nsg_summary_issues.json"
DIFF="nsg_diff_issues.json"
ASSOC="nsg_assoc_issues.json"
LIVE="nsg_live_bundle.json"

build_portal_url() {
  local rid="$1"
  echo "https://portal.azure.com/#resource${rid}"
}

dc=0
ac=0
if [ -f "$DIFF" ]; then
  dc=$(jq 'length' "$DIFF" 2>/dev/null || echo 0)
fi
if [ -f "$ASSOC" ]; then
  ac=$(jq 'length' "$ASSOC" 2>/dev/null || echo 0)
fi

rg_label="${AZURE_RESOURCE_GROUP:-subscription-wide}"
summary_text="NSG drift summary for subscription ${AZURE_SUBSCRIPTION_ID}, scope RG=${rg_label}. Rule drift issues: ${dc}. Association issues: ${ac}."

if [ -f "$LIVE" ]; then
  echo "=== NSG inventory (live export) ==="
  jq -r '.nsgs[] | "- \(.name) (rg: \(.resourceGroup)) id: \(.id)"' "$LIVE" || true
  echo ""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    nid=$(echo "$line" | jq -r '.id')
    nn=$(echo "$line" | jq -r '.name')
    url=$(build_portal_url "$nid")
    echo "Portal: $nn -> $url"
  done < <(jq -c '.nsgs[]?' "$LIVE" 2>/dev/null || true)
fi

echo ""
echo "$summary_text"
echo "Rollback: re-apply Terraform or pipeline that produced BASELINE_PATH; review Azure Activity Log for manual changes."

jq -n \
  --arg s "$summary_text" \
  --argjson dc "$dc" \
  --argjson ac "$ac" \
  'if ($dc > 0) or ($ac > 0) then
    [{
      title: ("NSG drift summary: " + ($dc|tostring) + " rule diff(s), " + ($ac|tostring) + " association issue(s)"),
      details: $s,
      severity: 2,
      next_steps: "Review nsg_diff_issues.json and nsg_assoc_issues.json; reconcile via IaC and confirm changes in Activity Log."
    }]
   else
    [{
      title: "No NSG rule or association drift detected in this run",
      details: $s,
      severity: 1,
      next_steps: "Keep baseline exports updated when changing NSGs in code."
    }]
   end' > "$OUT_ISSUES"

echo "Wrote $OUT_ISSUES"
