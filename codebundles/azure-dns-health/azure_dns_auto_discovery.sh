#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  azure_dns_auto_discovery.sh
#
#  PURPOSE:
#    Automatically discovers Azure DNS resources and suggests configuration
#    for the azure-dns-health codebundle. This reduces manual configuration
#    and makes the codebundle more Azure-specific.
#
#  REQUIRED ENV VARS
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to scan (optional, uses current)
#
#  OPTIONAL ENV VARS
#    RESOURCE_GROUPS                 Comma-separated list to limit scope
#    AUTO_CONFIGURE                  Set to "true" to output Robot Framework variables
# ---------------------------------------------------------------------------

set -euo pipefail

OUTPUT_FILE="azure_dns_discovery.json"
ROBOT_VARS_FILE="auto_discovered_vars.robot"

# Initialize output
discovery_results='{"discovery": {"resource_groups": [], "private_dns_zones": [], "public_dns_zones": [], "suggested_test_fqdns": [], "forward_lookup_zones": [], "express_route_zones": [], "dns_resolvers": []}}'

echo "=== Azure DNS Auto-Discovery ==="
echo "Discovering DNS resources in your Azure environment..."

# ---------------------------------------------------------------------------
# 1) Determine subscription ID
# ---------------------------------------------------------------------------
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
  if [[ -z "$subscription" ]]; then
    echo "ERROR: Not logged into Azure CLI. Run 'az login' first."
    exit 1
  fi
  echo "Using current Azure CLI subscription: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using specified subscription: $subscription"
fi

az account set --subscription "$subscription" 2>/dev/null || {
  echo "ERROR: Cannot access subscription $subscription"
  exit 1
}

# ---------------------------------------------------------------------------
# 2) Discover Resource Groups with DNS resources
# ---------------------------------------------------------------------------
echo "Discovering resource groups with DNS zones..."

if [[ -n "${RESOURCE_GROUPS:-}" ]]; then
  # User specified resource groups
  IFS=',' read -ra rg_array <<< "$RESOURCE_GROUPS"
  echo "Scanning specified resource groups: $RESOURCE_GROUPS"
else
  # Auto-discover resource groups with DNS zones
  echo "Auto-discovering resource groups with DNS resources..."
  
  # Find RGs with private DNS zones
  private_dns_rgs=$(az network private-dns zone list --query "[].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Find RGs with public DNS zones  
  public_dns_rgs=$(az network dns zone list --query "[].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Combine and deduplicate
  all_rgs=$(echo -e "$private_dns_rgs\n$public_dns_rgs" | grep -v '^$' | sort -u || echo "")
  
  if [[ -z "$all_rgs" ]]; then
    echo "WARNING: No DNS zones found in subscription. You may need to specify RESOURCE_GROUPS manually."
    rg_array=()
  else
    readarray -t rg_array <<< "$all_rgs"
    echo "Found DNS resources in resource groups: ${rg_array[*]}"
  fi
fi

# Update discovery results with resource groups
for rg in "${rg_array[@]}"; do
  discovery_results=$(echo "$discovery_results" | jq --arg rg "$rg" '.discovery.resource_groups += [$rg]')
done

# ---------------------------------------------------------------------------
# 3) Discover Private DNS Zones
# ---------------------------------------------------------------------------
echo "Discovering private DNS zones..."
private_zones=()
suggested_fqdns=()

for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" ]]; then
    zones=$(az network private-dns zone list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$zones" ]]; then
      while IFS= read -r zone; do
        if [[ -n "$zone" ]]; then
          private_zones+=("$zone")
          discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.private_dns_zones += [$zone]')
          
          # Check for common record types that suggest important services
          records=$(az network private-dns record-set list --resource-group "$rg" --zone-name "$zone" --query "[?type=='Microsoft.Network/privateDnsZones/A' || type=='Microsoft.Network/privateDnsZones/CNAME'].name" -o tsv 2>/dev/null || echo "")
          
          if [[ -n "$records" ]]; then
            while IFS= read -r record; do
              if [[ -n "$record" && "$record" != "@" ]]; then
                # Suggest FQDNs for common service patterns
                if [[ "$record" =~ (database|db|sql|mysql|postgres|redis|cache) ]]; then
                  suggested_fqdns+=("$record.$zone")
                elif [[ "$record" =~ (api|app|web|service|endpoint) ]]; then
                  suggested_fqdns+=("$record.$zone")
                elif [[ "$record" =~ (mail|smtp|exchange) ]]; then
                  suggested_fqdns+=("$record.$zone")
                fi
              fi
            done <<< "$records"
          fi
        fi
      done <<< "$zones"
    fi
  fi
done

echo "Found ${#private_zones[@]} private DNS zones"

# ---------------------------------------------------------------------------
# 4) Discover Public DNS Zones
# ---------------------------------------------------------------------------
echo "Discovering public DNS zones..."
public_zones=()

for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" ]]; then
    zones=$(az network dns zone list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$zones" ]]; then
      while IFS= read -r zone; do
        if [[ -n "$zone" ]]; then
          public_zones+=("$zone")
          discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.public_dns_zones += [$zone]')
          
          # Add root domain to suggested test FQDNs
          suggested_fqdns+=("$zone")
          
          # Check for common subdomains
          records=$(az network dns record-set list --resource-group "$rg" --zone-name "$zone" --query "[?type=='Microsoft.Network/dnszones/A' || type=='Microsoft.Network/dnszones/CNAME'].name" -o tsv 2>/dev/null || echo "")
          
          if [[ -n "$records" ]]; then
            while IFS= read -r record; do
              if [[ -n "$record" && "$record" != "@" ]]; then
                # Add common public-facing subdomains
                if [[ "$record" =~ ^(www|api|app|blog|mail|ftp)$ ]]; then
                  suggested_fqdns+=("$record.$zone")
                fi
              fi
            done <<< "$records"
          fi
        fi
      done <<< "$zones"
    fi
  fi
done

echo "Found ${#public_zones[@]} public DNS zones"

# ---------------------------------------------------------------------------
# 5) Detect Forward Lookup Zones (heuristic)
# ---------------------------------------------------------------------------
echo "Detecting potential forward lookup zones..."
forward_zones=()

# Look for private zones that might be forward lookup zones
for zone in "${private_zones[@]}"; do
  # Common patterns for internal/corporate domains
  if [[ "$zone" =~ \.(local|corp|internal|company|ad|domain)$ ]] || [[ "$zone" =~ ^(internal|corp|company)\. ]]; then
    forward_zones+=("$zone")
    discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.forward_lookup_zones += [$zone]')
  fi
done

echo "Found ${#forward_zones[@]} potential forward lookup zones"

# ---------------------------------------------------------------------------
# 6) Detect Express Route related zones
# ---------------------------------------------------------------------------
echo "Detecting Express Route related zones..."
express_route_zones=()

# Look for zones that might be accessed via Express Route
for zone in "${private_zones[@]}"; do
  # Check if zone has records that suggest on-premises connectivity
  for rg in "${rg_array[@]}"; do
    if [[ -n "$rg" ]]; then
      # Look for A records with private IP ranges that suggest on-premises
      records=$(az network private-dns record-set a list --resource-group "$rg" --zone-name "$zone" --query "[].aRecords[].ipv4Address" -o tsv 2>/dev/null || echo "")
      
      if [[ -n "$records" ]]; then
        while IFS= read -r ip; do
          # Check for common on-premises IP ranges
          if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
            if [[ ! " ${express_route_zones[*]} " =~ " $zone " ]]; then
              express_route_zones+=("$zone")
              discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.express_route_zones += [$zone]')
            fi
            break
          fi
        done <<< "$records"
      fi
    fi
  done
done

echo "Found ${#express_route_zones[@]} potential Express Route zones"

# ---------------------------------------------------------------------------
# 7) Discover Custom DNS Resolvers
# ---------------------------------------------------------------------------
echo "Discovering custom DNS resolvers..."
dns_resolvers=()

# Add Azure DNS resolver (168.63.129.16) - always available in Azure VMs
dns_resolvers+=("168.63.129.16")

# Look for custom DNS resolvers in each resource group
for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" ]]; then
    # Check for Azure DNS Private Resolvers
    resolver_list=$(az network dns-resolver list --resource-group "$rg" --query "[?provisioningState=='Succeeded'].{name:name,id:id}" -o json 2>/dev/null || echo "[]")
    if [[ "$resolver_list" != "[]" && "$resolver_list" != "" ]]; then
      # Get inbound endpoints for each resolver
      while IFS= read -r resolver_id; do
        if [[ -n "$resolver_id" ]]; then
          resolver_name=$(basename "$resolver_id")
          inbound_endpoints=$(az network dns-resolver inbound-endpoint list --dns-resolver-name "$resolver_name" --resource-group "$rg" --query "[?provisioningState=='Succeeded'].ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || echo "")
          if [[ -n "$inbound_endpoints" ]]; then
            while IFS= read -r ip; do
              if [[ -n "$ip" && "$ip" != "null" ]]; then
                dns_resolvers+=("$ip")
              fi
            done <<< "$inbound_endpoints"
          fi
        fi
      done <<< "$(echo "$resolver_list" | jq -r '.[].id' 2>/dev/null || echo "")"
    fi
    
    # Check for custom DNS servers in VNet configurations
    vnet_dns=$(az network vnet list --resource-group "$rg" --query "[].dhcpOptions.dnsServers[]" -o tsv 2>/dev/null || echo "")
    if [[ -n "$vnet_dns" ]]; then
      while IFS= read -r dns_ip; do
        if [[ -n "$dns_ip" && "$dns_ip" != "null" ]]; then
          dns_resolvers+=("$dns_ip")
        fi
      done <<< "$vnet_dns"
    fi
  fi
done

# Add common public DNS resolvers as fallback
dns_resolvers+=("8.8.8.8")
dns_resolvers+=("1.1.1.1")

# Remove duplicates and update discovery results
unique_dns_resolvers=($(printf "%s\n" "${dns_resolvers[@]}" | sort -u))
for resolver in "${unique_dns_resolvers[@]}"; do
  discovery_results=$(echo "$discovery_results" | jq --arg resolver "$resolver" '.discovery.dns_resolvers += [$resolver]')
done

echo "Found ${#unique_dns_resolvers[@]} DNS resolvers"

# ---------------------------------------------------------------------------
# 8) Finalize suggested test FQDNs
# ---------------------------------------------------------------------------
# Remove duplicates and add to discovery results
unique_fqdns=($(printf '%s\n' "${suggested_fqdns[@]}" | sort -u))

for fqdn in "${unique_fqdns[@]}"; do
  discovery_results=$(echo "$discovery_results" | jq --arg fqdn "$fqdn" '.discovery.suggested_test_fqdns += [$fqdn]')
done

# ---------------------------------------------------------------------------
# 9) Output results
# ---------------------------------------------------------------------------
echo "$discovery_results" | jq . > "$OUTPUT_FILE"

echo ""
echo "=== Discovery Complete ==="
echo "Results saved to: $OUTPUT_FILE"
echo ""
echo "Summary:"
echo "- Resource Groups: ${#rg_array[@]}"
echo "- Private DNS Zones: ${#private_zones[@]}"
echo "- Public DNS Zones: ${#public_zones[@]}"
echo "- Suggested Test FQDNs: ${#unique_fqdns[@]}"
echo "- Forward Lookup Zones: ${#forward_zones[@]}"
echo "- Express Route Zones: ${#express_route_zones[@]}"

# ---------------------------------------------------------------------------
# 10) Generate Robot Framework variables (if requested)
# ---------------------------------------------------------------------------
if [[ "${AUTO_CONFIGURE:-}" == "true" ]]; then
  echo ""
  echo "Generating Robot Framework variables..."
  
  cat > "$ROBOT_VARS_FILE" << EOF
*** Variables ***
# Auto-discovered Azure DNS configuration
# Generated on $(date)

# Resource Groups (comma-separated)
\${RESOURCE_GROUPS}    $(IFS=','; echo "${rg_array[*]}")

# Test FQDNs (comma-separated) - Important domains/services to monitor
\${TEST_FQDNS}    $(IFS=','; echo "${unique_fqdns[*]}")

# Forward Lookup Zones (comma-separated) - Internal domains forwarded to on-premises
\${FORWARD_LOOKUP_ZONES}    $(IFS=','; echo "${forward_zones[*]}")

# Public Domains (comma-separated) - Your public websites
\${PUBLIC_DOMAINS}    $(IFS=','; echo "${public_zones[*]}")

# Express Route DNS Zones (comma-separated) - Domains accessed through Express Route
\${EXPRESS_ROUTE_DNS_ZONES}    $(IFS=','; echo "${express_route_zones[*]}")

# DNS Resolvers (comma-separated) - Custom DNS servers (empty = use defaults)
\${DNS_RESOLVERS}    

# Forward Zone Test Subdomains (comma-separated) - Specific servers to test
\${FORWARD_ZONE_TEST_SUBDOMAINS}    dc01,mail,web
EOF

  echo "Robot Framework variables saved to: $ROBOT_VARS_FILE"
  echo ""
  echo "To use these variables:"
  echo "1. Review and edit $ROBOT_VARS_FILE as needed"
  echo "2. Import the variables in your Robot Framework test"
  echo "3. Or copy the values to your configuration"
fi

echo ""
echo "=== Recommended Configuration ==="
echo "Based on discovery, here's your suggested minimal configuration:"
echo ""
echo "RESOURCE_GROUPS: $(IFS=','; echo "${rg_array[*]}")"
echo "TEST_FQDNS: $(IFS=','; echo "${unique_fqdns[*]:0:5}")"  # Limit to first 5 for readability

if [[ ${#forward_zones[@]} -gt 0 ]]; then
  echo "FORWARD_LOOKUP_ZONES: $(IFS=','; echo "${forward_zones[*]}")"
fi

if [[ ${#public_zones[@]} -gt 0 ]]; then
  echo "PUBLIC_DOMAINS: $(IFS=','; echo "${public_zones[*]}")"
fi

if [[ ${#express_route_zones[@]} -gt 0 ]]; then
  echo "EXPRESS_ROUTE_DNS_ZONES: $(IFS=','; echo "${express_route_zones[*]}")"
fi

