#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_config_health.sh
#  • service_bus_namespace.txt   – plain-text summary for report
#  • service_bus_config_health.json – issues array for automation
# ---------------------------------------------------------------------------

set -euo pipefail

OUT_TXT="service_bus_namespace.txt"
OUT_ISSUES="service_bus_config_health.json"

: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

##############################################################################
# 1) Pull namespace properties
##############################################################################
ns_json=$(az servicebus namespace show \
            --name "$SB_NAMESPACE_NAME" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            -o json)

##############################################################################
# 2) Human-readable snapshot (plain text)
##############################################################################
name=$(jq -r '.name'               <<<"$ns_json")
loc=$(jq -r '.location'            <<<"$ns_json")
sku=$(jq -r '.sku.name'            <<<"$ns_json")
cap=$(jq -r '.sku.capacity // "-"' <<<"$ns_json")
tls=$(jq -r '.minimumTlsVersion'   <<<"$ns_json")
pna=$(jq -r '.publicNetworkAccess' <<<"$ns_json")
identity=$(jq -r '.identity.type // "None"' <<<"$ns_json")
zone=$(jq -r '.zoneRedundant // false'      <<<"$ns_json")

cat > "$OUT_TXT" <<EOF
Service Bus Namespace Configuration
-----------------------------------
Name:                 $name
Resource Group:       $AZ_RESOURCE_GROUP
Location:             $loc
SKU:                  $sku
Capacity (MU):        $cap
TLS Minimum Version:  $tls
Public Network:       $pna
Managed Identity:     $identity
Zone Redundant:       $zone
EOF
echo "📝  Wrote summary -> $OUT_TXT"

##############################################################################
# 3) Build issues list
##############################################################################
issues='[]'
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
                --arg n "$next" --arg d "$details" \
                '. += [ {severity:($s|tonumber),title:$t,next_step:$n,details:$d} ]' \
                <<<"$issues")
}

ns_bt="\`$SB_NAMESPACE_NAME\`"   # back-ticked

# --- Rules that apply to ALL SKUs --------------------------------------------------
[[ "$tls" != 1.2 && "$tls" != 1.3 ]] && add_issue 4 \
  "TLS minimum version for $ns_bt is $tls (≥1.2 recommended)" \
  "az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --minimum-tls-version 1.2" \
  "minimumTlsVersion=$tls"

[[ "$pna" == "Enabled" ]] && add_issue 4 \
  "Public network access enabled on $ns_bt" \
  "Disable or restrict public access via firewall / Private Link" \
  "publicNetworkAccess=Enabled"

[[ "$identity" == "None" ]] && add_issue 4 \
  "No managed identity assigned to $ns_bt" \
  "az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --assign-identity" \
  "identity.type=None"

# --- Premium-only features ----------------------------------------------------------
if [[ "$sku" == "Premium" ]]; then
  # Zone redundancy check (real warning)
  [[ "$zone" != "true" ]] && add_issue 4 \
    "Zone redundancy disabled on Premium $ns_bt" \
    "az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --zone-redundant true" \
    "zoneRedundant=$zone"
else
  # Informational note for Standard/Basic
  add_issue 4 \
    "Zone redundancy not available on $sku SKU ($ns_bt)" \
    "Upgrade to Premium if multi-AZ availability is required" \
    "zoneRedundant property ignored on $sku tier"
fi

##############################################################################
# 4) Emit machine-readable issues JSON
##############################################################################
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$OUT_ISSUES"

echo "✅  Wrote issues JSON -> $OUT_ISSUES"
