#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   VNET_NAME
#
# Reads discovered_subnets.json (from discovery task) or re-queries subnets.
# Outputs: subnet_nsg_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_ISSUES="subnet_nsg_issues.json"
DISCOVERY="discovered_subnets.json"
issues_json='[]'

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" >/dev/null 2>&1 || true

if [[ -f "$DISCOVERY" ]]; then
  subnets=$(cat "$DISCOVERY")
else
  subnets=$(az network vnet subnet list \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    -o json)
fi

extract_rg_from_id() {
  echo "$1" | awk -F/ '{print $5}'
}

extract_name_from_id() {
  echo "$1" | awk -F/ '{print $9}'
}

while IFS= read -r row; do
  sname=$(echo "$row" | jq -r '.name')
  nsg_id=$(echo "$row" | jq -r '.networkSecurityGroup.id // empty')
  if [[ -z "$nsg_id" || "$nsg_id" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`${sname}\` Has No Subnet-Level NSG" \
      --arg details "No networkSecurityGroup attached at subnet scope. Traffic may rely on NIC NSGs or Azure defaults only." \
      --arg severity "2" \
      --arg next_steps "If policy requires subnet-level NSG, associate an NSG with this subnet or document NIC-level controls." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
    continue
  fi
  nsg_rg=$(extract_rg_from_id "$nsg_id")
  nsg_name=$(extract_name_from_id "$nsg_id")
  if ! rules_json=$(az network nsg rule list \
    --resource-group "$nsg_rg" \
    --nsg-name "$nsg_name" \
    -o json 2>err_nsg.log); then
    err_msg=$(cat err_nsg.log 2>/dev/null || echo "error")
    rm -f err_nsg.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Read NSG Rules for Subnet \`${sname}\`" \
      --arg details "Failed to list rules for NSG $nsg_name: $err_msg" \
      --arg severity "3" \
      --arg next_steps "Verify Reader access on the NSG resource group and that the NSG exists." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
    continue
  fi
  rm -f err_nsg.log

  deny_out=$(echo "$rules_json" | jq '[.[] | select(.direction=="Outbound" and .access=="Deny")] | length')
  allow_out=$(echo "$rules_json" | jq '[.[] | select(.direction=="Outbound" and .access=="Allow")] | length')
  if [[ "$deny_out" -eq 0 && "$allow_out" -gt 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`${sname}\` NSG Has No Explicit Outbound Deny Rules" \
      --arg details "NSG \`$nsg_name\` has $allow_out outbound allow rule(s) and no explicit deny rules (default deny still applies where no allow matches)." \
      --arg severity "2" \
      --arg next_steps "Review outbound allow rules for least privilege; add explicit denies if required by policy." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
done < <(echo "$subnets" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "NSG egress summary written to $OUTPUT_ISSUES"
