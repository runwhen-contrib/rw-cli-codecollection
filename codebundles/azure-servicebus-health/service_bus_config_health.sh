#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_config_health.sh
#  • service_bus_namespace.txt   – plain-text summary for report
#  • service_bus_config_health.json – issues array for automation
# ---------------------------------------------------------------------------

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

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
