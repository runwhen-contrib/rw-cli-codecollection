#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Validates subnet and NIC associations for NSGs in scope; optionally compares
# to ASSOCIATION_BASELINE_PATH JSON. Writes nsg_assoc_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
OUTPUT_BUNDLE="nsg_live_bundle.json"
OUTPUT_ISSUES="nsg_assoc_issues.json"
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
    --arg t "Azure Login Failed for NSG Association Audit" \
    --arg d "Could not authenticate for subscription $AZURE_SUBSCRIPTION_ID" \
    --arg n "Verify azure_credentials and Reader role." \
    --argjson sev 3 \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  exit 0
}

RG="${AZURE_RESOURCE_GROUP:-}"
NSG_FILTER="${NSG_NAMES:-All}"
if [ -n "${NSG_NAME:-}" ]; then
  NSG_FILTER="$NSG_NAME"
fi

collect_assoc() {
  local rg="$1" n="$2"
  local raw
  raw=$(az network nsg show -g "$rg" -n "$n" --subscription "$AZURE_SUBSCRIPTION_ID" -o json 2>/dev/null) || return 1
  echo "$raw" | jq -c '{
    subnets: ((.subnets // []) | map(.id)),
    networkInterfaces: ((.networkInterfaces // []) | map(.id))
  }'
}

if [ ! -f "$OUTPUT_BUNDLE" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Missing Live NSG Export" \
    --arg d "Run Export Live NSG Rules before association audit (expected $OUTPUT_BUNDLE)" \
    --arg n "Execute tasks in order: export, load baseline, diff, then association." \
    --argjson sev 2 \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
  echo "$issues_json" | jq '.' > "$OUTPUT_ISSUES"
  exit 0
fi

assoc_base=""
if [ -n "${ASSOCIATION_BASELINE_PATH:-}" ] && [ -f "$ASSOCIATION_BASELINE_PATH" ]; then
  assoc_base=$(cat "$ASSOCIATION_BASELINE_PATH")
fi

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
  if ! live_a=$(collect_assoc "$rg" "$n"); then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Cannot Load Associations for \`$n\`" \
      --arg d "az network nsg show failed" \
      --arg n "Confirm Reader on Microsoft.Network/networkSecurityGroups." \
      --argjson sev 3 \
      '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    continue
  fi
  base_entry=""
  if [ -n "$assoc_base" ]; then
    base_entry=$(echo "$assoc_base" | jq -c --arg name "$n" --arg rg "$rg" \
      '(.nsgs // [])[] | select(.name == $name and ((.resourceGroup // "") == ($rg)))' 2>/dev/null | head -1)
  fi
  if [ -n "$assoc_base" ] && [ -n "$base_entry" ] && [ "$base_entry" != "null" ]; then
    exp_s=$(echo "$base_entry" | jq -c '.subnetIds // []')
    exp_n=$(echo "$base_entry" | jq -c '.nicIds // []')
    got_s=$(echo "$live_a" | jq -c '.subnets')
    got_n=$(echo "$live_a" | jq -c '.networkInterfaces')
    if [ "$(echo "$exp_s" | jq -c 'sort')" != "$(echo "$got_s" | jq -c 'sort')" ] || \
       [ "$(echo "$exp_n" | jq -c 'sort')" != "$(echo "$got_n" | jq -c 'sort')" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Association Drift for NSG \`$n\`" \
        --arg d "$(echo "$live_a" | jq -c --argjson exp "$base_entry" '{expected: $exp, live: .}')" \
        --arg n "Subnet or NIC association changed vs baseline; verify routing intent." \
        --argjson sev 3 \
        '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    fi
  else
    # Informational: surface association inventory when no baseline compare
    sn=$(echo "$live_a" | jq '(.subnets | length) + (.networkInterfaces | length)')
    if [ "${sn:-0}" -eq 0 ] && [ "${REQUIRE_ASSOCIATIONS:-false}" = "true" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "NSG \`$n\` Has No Subnet or NIC Attachments" \
        --arg d "No subnets or NICs reference this NSG (may be intentional)." \
        --arg n "Detach unused NSGs from inventory or attach as designed." \
        --argjson sev 2 \
        '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $n}]')
    fi
  fi
done < <(jq -c '.nsgs[]?' "$OUTPUT_BUNDLE")

echo "$issues_json" | jq '.' > "$OUTPUT_ISSUES"
echo "Association audit written to $OUTPUT_ISSUES"
