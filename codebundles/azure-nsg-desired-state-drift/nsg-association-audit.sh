#!/usr/bin/env bash
# Compare subnet/NIC associations between live export and baseline (if present).
# Inputs: nsg_live_export.json, nsg_baseline_normalized.json
# Output: nsg_association_issues.json
set -euo pipefail
set -x

LIVE="${LIVE_EXPORT_FILE:-nsg_live_export.json}"
BASE="${BASELINE_FILE:-nsg_baseline_normalized.json}"
OUT="nsg_association_issues.json"
issues_json='[]'

if [ ! -f "$LIVE" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Association audit skipped: missing live export" \
    --arg details "File $LIVE not found." \
    --argjson severity 2 \
    --arg next_steps "Run the live export task first." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" | jq . > "$OUT"
  exit 0
fi

NSG_NAME=$(jq -r '.nsgName' "$LIVE")

LIVE_SUB=$(jq -c '.associations.subnetIds // [] | sort' "$LIVE")
LIVE_NIC=$(jq -c '.associations.networkInterfaceIds // [] | sort' "$LIVE")

if [ ! -f "$BASE" ]; then
  echo "$issues_json" | jq . > "$OUT"
  echo "No baseline file; skipping association comparison."
  exit 0
fi

HAS_BASE_ASSOC=$(jq 'has("associations") and (.associations | type == "object")' "$BASE")
if [ "$HAS_BASE_ASSOC" != "true" ]; then
  echo "$issues_json" | jq . > "$OUT"
  echo "Baseline has no associations block; skipping association drift."
  exit 0
fi

BASE_SUB=$(jq -c '.associations.subnetIds // [] | sort' "$BASE")
BASE_NIC=$(jq -c '.associations.networkInterfaceIds // [] | sort' "$BASE")

SUB_MATCH=$(jq -n --argjson a "$LIVE_SUB" --argjson b "$BASE_SUB" '$a == $b')
if [ "$SUB_MATCH" != "true" ]; then
  details=$(jq -n --argjson live "$LIVE_SUB" --argjson base "$BASE_SUB" '{subnets:{live:$live,baseline:$base}}')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Subnet association drift for NSG \`$NSG_NAME\`" \
    --arg details "$(echo "$details" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Verify subnet NSG attachments in Azure Portal or VNet configuration vs baseline." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
fi

NIC_MATCH=$(jq -n --argjson a "$LIVE_NIC" --argjson b "$BASE_NIC" '$a == $b')
if [ "$NIC_MATCH" != "true" ]; then
  details=$(jq -n --argjson live "$LIVE_NIC" --argjson base "$BASE_NIC" '{networkInterfaces:{live:$live,baseline:$base}}')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "NIC association drift for NSG \`$NSG_NAME\`" \
    --arg details "$(echo "$details" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Review NIC NSG assignments; reconcile via IaC or update baseline." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
fi

echo "$issues_json" | jq . > "$OUT"
echo "Association audit wrote $OUT"
