#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Exports live NSG rules to nsg_live_bundle.json (canonical schema) for drift comparison.
# Required: AZURE_SUBSCRIPTION_ID, NSG_NAME (or NSG_NAMES / scope via AZURE_RESOURCE_GROUP)
# Optional: AZURE_RESOURCE_GROUP (empty = list NSGs in subscription), NSG_NAMES (All | comma list)
# Output: nsg_live_bundle.json, nsg_export_issues.json (issue array)
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
OUTPUT_BUNDLE="nsg_live_bundle.json"
OUTPUT_ISSUES="nsg_export_issues.json"
issues_json='[]'

login_azure() {
  az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true
  if az account show --subscription "$AZURE_SUBSCRIPTION_ID" >/dev/null 2>&1; then
    return 0
  fi
  local cid csec tid
  if [ -n "${AZURE_CREDENTIALS:-}" ]; then
    cid=$(echo "$AZURE_CREDENTIALS" | jq -r '.AZURE_CLIENT_ID // .clientId // empty')
    csec=$(echo "$AZURE_CREDENTIALS" | jq -r '.AZURE_CLIENT_SECRET // .clientSecret // empty')
    tid=$(echo "$AZURE_CREDENTIALS" | jq -r '.AZURE_TENANT_ID // .tenantId // empty')
  else
    cid=${AZURE_CLIENT_ID:-}
    csec=${AZURE_CLIENT_SECRET:-}
    tid=${AZURE_TENANT_ID:-}
  fi
  if [ -n "${cid:-}" ] && [ -n "${csec:-}" ] && [ -n "${tid:-}" ]; then
    az login --service-principal -u "$cid" -p "$csec" --tenant "$tid" >/dev/null
  fi
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
}

login_azure || {
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Azure Login Failed for NSG Export" \
    --arg d "Could not authenticate to subscription $AZURE_SUBSCRIPTION_ID" \
    --arg n "Verify azure_credentials secret (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET) and Reader role on the subscription." \
    '. += [{"title": $t, "details": $d, "severity": 4, "next_steps": $n}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo '{"schemaVersion":"1","subscriptionId":"","exportedAt":"","nsgs":[]}' | jq --arg s "$AZURE_SUBSCRIPTION_ID" '.subscriptionId=$s' > "$OUTPUT_BUNDLE"
  echo "Azure login failed"
  exit 0
}

RG="${AZURE_RESOURCE_GROUP:-}"
NSG_FILTER="${NSG_NAMES:-All}"
if [ -n "${NSG_NAME:-}" ]; then
  NSG_FILTER="$NSG_NAME"
fi

normalize_nsg() {
  jq '
    def fr($r):
      ($r.properties // $r) as $p
      | {
          name: ($r.name // ""),
          priority: ($p.priority // 0),
          direction: ($p.direction // ""),
          access: ($p.access // ""),
          protocol: ($p.protocol // ""),
          sourcePortRange: ($p.sourcePortRange // ""),
          destinationPortRange: ($p.destinationPortRange // ""),
          sourceAddressPrefix: ($p.sourceAddressPrefix // ""),
          destinationAddressPrefix: ($p.destinationAddressPrefix // ""),
          sourceAddressPrefixes: ($p.sourceAddressPrefixes // [] | sort),
          destinationAddressPrefixes: ($p.destinationAddressPrefixes // [] | sort),
          sourcePortRanges: ($p.sourcePortRanges // [] | sort),
          destinationPortRanges: ($p.destinationPortRanges // [] | sort),
          description: ($p.description // "")
        };
    {
      schemaVersion: "1",
      subscriptionId: (if (.id|type) == "string" and (.id|length) > 0 then (.id|split("/")[2]) else "" end),
      resourceGroup: (.resourceGroup // (try (.id | capture("/resourceGroups/(?<g>[^/]+)/") | .g) catch "")),
      name: (.name // ""),
      id: (.id // ""),
      securityRules: ((.securityRules // []) | map(fr(.)) | sort_by(.priority, .name)),
      defaultSecurityRules: ((.defaultSecurityRules // []) | map(fr(.)) | sort_by(.priority, .name))
    }
  '
}

list_nsgs_json() {
  if [ -n "$RG" ]; then
    az network nsg list -g "$RG" --subscription "$AZURE_SUBSCRIPTION_ID" -o json
  else
    az network nsg list --subscription "$AZURE_SUBSCRIPTION_ID" -o json
  fi
}

nsg_entries='[]'
while IFS= read -r row; do
  [ -z "$row" ] && continue
  n=$(echo "$row" | jq -r '.name')
  rg=$(echo "$row" | jq -r '.resourceGroup')
  if [ "$NSG_FILTER" != "All" ] && [ "$NSG_FILTER" != "all" ]; then
    match=0
    IFS=',' read -ra _parts <<< "$NSG_FILTER"
    for p in "${_parts[@]}"; do
      pp=$(echo "$p" | xargs)
      if [ "$n" = "$pp" ]; then match=1; break; fi
    done
    if [ "$match" -eq 0 ]; then continue; fi
  fi
  if ! raw=$(az network nsg show -g "$rg" -n "$n" --subscription "$AZURE_SUBSCRIPTION_ID" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Cannot Read NSG \`$n\`" \
      --arg d "az network nsg show failed in resource group $rg" \
      --arg n "Confirm Reader on Microsoft.Network and that the NSG exists." \
      --argjson sev 3 \
      '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    continue
  fi
  norm=$(echo "$raw" | normalize_nsg)
  nsg_entries=$(echo "$nsg_entries" | jq --argjson x "$norm" '. += [$x]')
done < <(list_nsgs_json | jq -c '.[]')

if [ "$(echo "$nsg_entries" | jq 'length')" -eq 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No NSGs Found in Scope" \
    --arg d "No network security groups matched subscription=$AZURE_SUBSCRIPTION_ID resourceGroup=${RG:-<all>} filter=$NSG_FILTER" \
    --arg n "Adjust AZURE_RESOURCE_GROUP, NSG_NAMES, or NSG_NAME; confirm resources exist." \
    --argjson sev 2 \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
fi

bundle=$(jq -n \
  --arg sid "$AZURE_SUBSCRIPTION_ID" \
  --argjson nsgs "$nsg_entries" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{schemaVersion: "1", subscriptionId: $sid, exportedAt: $ts, nsgs: $nsgs}')
echo "$bundle" | jq '.' > "$OUTPUT_BUNDLE"
echo "$issues_json" | jq '.' > "$OUTPUT_ISSUES"
echo "Exported $(echo "$bundle" | jq '.nsgs | length') NSG(s) to $OUTPUT_BUNDLE"
