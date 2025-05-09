#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_config_health.sh
#  • service_bus_namespace.txt   – plain-text summary for human report
#  • service_bus_config_health.json – machine-readable issues list
# ---------------------------------------------------------------------------

set -euo pipefail

OUT_TXT="service_bus_namespace.txt"
OUT_ISSUES="service_bus_config_health.json"

: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

##############################################################################
# 1) Fetch namespace JSON once
##############################################################################
ns_json=$(az servicebus namespace show \
            --name "$SB_NAMESPACE_NAME" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            -o json)

##############################################################################
# 2) Plain-text summary for the report
##############################################################################
name=$(jq -r '.name' <<<"$ns_json")
loc=$(jq -r '.location' <<<"$ns_json")
sku=$(jq -r '.sku.name' <<<"$ns_json")
cap=$(jq -r '.sku.capacity' <<<"$ns_json")
tls=$(jq -r '.minimumTlsVersion' <<<"$ns_json")
pna=$(jq -r '.publicNetworkAccess' <<<"$ns_json")
identity=$(jq -r '.identity.type // "None"' <<<"$ns_json")
zone=$(jq -r '.zoneRedundant // false' <<<"$ns_json")

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
echo "📝  Wrote human summary -> $OUT_TXT"

##############################################################################
# 3) Build issues array for automation
##############################################################################
issues='[]'
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
                --arg n "$next" --arg d "$details" \
                '. += [ {severity:($s|tonumber),title:$t,next_step:$n,details:$d} ]' \
                <<<"$issues")
}

ns_backtick="\`$SB_NAMESPACE_NAME\`"

# TLS version
if [[ "$tls" != 1.2 && "$tls" != 1.3 ]]; then
  add_issue 3 \
    "TLS minimum version for Service Bus $ns_backtick is $tls (should be ≥1.2)" \
    "Run: \`az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --minimum-tls-version 1.2\`" \
    "minimumTlsVersion=$tls"
fi

# Public network access
if [[ "$pna" == "Enabled" ]]; then
  add_issue 2 \
    "Public network access enabled on $ns_backtick" \
    "Disable public access or restrict via firewall / Private Link for $ns_backtick" \
    "publicNetworkAccess=Enabled"
fi

# Managed identity
if [[ "$identity" == "None" ]]; then
  add_issue 2 \
    "No managed identity assigned to $ns_backtick" \
    "Assign a system identity: \`az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --assign-identity\`" \
    "identity.type=None"
fi

# Zone redundancy (Premium only)
if [[ "$sku" == "Premium" && "$zone" != "true" ]]; then
  add_issue 1 \
    "Zone redundancy disabled on Premium Service Bus $ns_backtick" \
    "Enable zone redundancy: \`az servicebus namespace update -g $AZ_RESOURCE_GROUP -n $SB_NAMESPACE_NAME --zone-redundant true\`" \
    "zoneRedundant=$zone"
fi

##############################################################################
# 4) Emit issues JSON
##############################################################################
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$OUT_ISSUES"

echo "✅  Wrote issues JSON -> $OUT_ISSUES"
