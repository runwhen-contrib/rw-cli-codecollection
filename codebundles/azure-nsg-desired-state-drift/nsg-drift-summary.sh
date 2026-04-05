#!/usr/bin/env bash
# Aggregate drift counts and emit operator summary with Portal links.
# Output: nsg_summary_issues.json (optional informational issue), stdout summary
set -euo pipefail
set -x

LIVE="${LIVE_EXPORT_FILE:-nsg_live_export.json}"
DIFF_ISSUES="${DIFF_ISSUES_FILE:-nsg_diff_issues.json}"
ASSOC_ISSUES="${ASSOC_ISSUES_FILE:-nsg_association_issues.json}"
OUT="nsg_summary_issues.json"

issues_json='[]'

if [ ! -f "$LIVE" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Summary unavailable: missing live NSG export" \
    --arg details "Expected $LIVE." \
    --argjson severity 2 \
    --arg next_steps "Run export task successfully before summary." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" | jq . > "$OUT"
  exit 0
fi

SUB=$(jq -r '.subscriptionId' "$LIVE")
RG=$(jq -r '.resourceGroup' "$LIVE")
NSG_NAME=$(jq -r '.nsgName' "$LIVE")
RID=$(jq -r '.resourceId' "$LIVE")

PORTAL_URL="https://portal.azure.com/#resource${RID}/overview"

DIFF_COUNT=0
if [ -f "$DIFF_ISSUES" ]; then
  DIFF_COUNT=$(jq 'length' "$DIFF_ISSUES" 2>/dev/null || echo 0)
fi
DIFF_COUNT=${DIFF_COUNT:-0}

ASSOC_COUNT=0
if [ -f "$ASSOC_ISSUES" ]; then
  ASSOC_COUNT=$(jq 'length' "$ASSOC_ISSUES" 2>/dev/null || echo 0)
fi
ASSOC_COUNT=${ASSOC_COUNT:-0}

TOTAL=$((DIFF_COUNT + ASSOC_COUNT))

SUMMARY=$(jq -n \
  --arg sub "$SUB" \
  --arg rg "$RG" \
  --arg nsg "$NSG_NAME" \
  --arg url "$PORTAL_URL" \
  --argjson dc "$DIFF_COUNT" \
  --argjson ac "$ASSOC_COUNT" \
  --argjson tot "$TOTAL" \
  '{
    subscriptionId: $sub,
    resourceGroup: $rg,
    nsgName: $nsg,
    portalUrl: $url,
    ruleDriftIssues: $dc,
    associationDriftIssues: $ac,
    totalDriftIssues: $tot,
    rollbackHint: "Revert via Terraform/Bicep apply or re-run pipeline from known-good commit; avoid manual portal edits."
  }')

echo "$SUMMARY" | jq .

echo ""
echo "=== NSG drift summary: $NSG_NAME (RG: $RG) ==="
echo "Subscription: $SUB"
echo "Portal:       $PORTAL_URL"
echo "Rule/association drift issues: $TOTAL (rules: $DIFF_COUNT, associations: $ASSOC_COUNT)"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No NSG drift detected for \`$NSG_NAME\`" \
    --arg details "$(echo "$SUMMARY" | jq -c .)" \
    --argjson severity 1 \
    --arg next_steps "Keep baselines updated when IaC changes; continue periodic drift checks." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
else
  issues_json=$(echo "$issues_json" | jq \
    --arg title "NSG drift summary: $TOTAL issue(s) for \`$NSG_NAME\`" \
    --arg details "$(echo "$SUMMARY" | jq -c .)" \
    --argjson severity 2 \
    --arg next_steps "Review detailed rule and association tasks; rollback via pipeline or update baseline after approval." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
fi

echo "$issues_json" | jq . > "$OUT"
