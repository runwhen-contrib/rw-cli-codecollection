#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  azure_dns_smart_discovery.sh
#
#  PURPOSE:
#    Smart Azure DNS autodiscovery that focuses on ACTUAL Azure DNS configuration
#    instead of generic public resolvers. Discovers what DNS infrastructure
#    is actually configured and being used in the Azure environment.
#
#  APPROACH:
#    1. Find VNets and their configured DNS servers
#    2. Discover Private DNS Zones with actual records
#    3. Find Azure DNS Private Resolvers
#    4. Identify Express Route DNS forwarders
#    5. Suggest meaningful test FQDNs based on actual records
# ---------------------------------------------------------------------------

set -euo pipefail

OUTPUT_FILE="azure_dns_discovery.json"

echo "=== Smart Azure DNS Discovery ==="
echo "Analyzing actual Azure DNS configuration..."

# Initialize output
discovery_results='{"discovery": {"resource_groups": [], "private_dns_zones": [], "public_dns_zones": [], "suggested_test_fqdns": [], "forward_lookup_zones": [], "express_route_zones": [], "dns_resolvers": []}}'

# ---------------------------------------------------------------------------
# 1) Get subscription
# ---------------------------------------------------------------------------
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
  if [[ -z "$subscription" ]]; then
    echo "ERROR: Not logged into Azure CLI. Run 'az login' first."
    exit 1
  fi
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
fi

az account set --subscription "$subscription" 2>/dev/null || {
  echo "ERROR: Cannot access subscription $subscription"
  exit 1
}

echo "Analyzing subscription: $subscription"

# ---------------------------------------------------------------------------
# 2) Smart Resource Group Discovery - Find RGs with actual DNS resources
# ---------------------------------------------------------------------------
echo "Finding resource groups with DNS infrastructure..."

if [[ -n "${RESOURCE_GROUPS:-}" ]]; then
  # User specified - use those
  IFS=',' read -ra rg_array <<< "$RESOURCE_GROUPS"
  echo "Using specified resource groups: $RESOURCE_GROUPS"
else
  # Smart discovery: Find RGs with DNS zones OR VNets with custom DNS
  echo "Auto-discovering resource groups with DNS resources..."
  
  # Find RGs with private DNS zones
  private_dns_rgs=$(az network private-dns zone list --query "[].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Find RGs with public DNS zones  
  public_dns_rgs=$(az network dns zone list --query "[].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Find RGs with VNets that have custom DNS servers configured
  vnet_dns_rgs=$(az network vnet list --query "[?dhcpOptions.dnsServers != null].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Find RGs with DNS Private Resolvers
  dns_resolver_rgs=$(az network dns-resolver list --query "[].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Combine and deduplicate
  all_rgs=$(echo -e "$private_dns_rgs\n$public_dns_rgs\n$vnet_dns_rgs\n$dns_resolver_rgs" | grep -v '^$' | sort -u || echo "")
  
  if [[ -z "$all_rgs" ]]; then
    echo "WARNING: No DNS infrastructure found in subscription."
    rg_array=()
  else
    readarray -t rg_array <<< "$all_rgs"
    echo "Found DNS infrastructure in resource groups: ${rg_array[*]}"
  fi
fi

# Update discovery results with resource groups
for rg in "${rg_array[@]}"; do
  [[ -n "$rg" ]] && discovery_results=$(echo "$discovery_results" | jq --arg rg "$rg" '.discovery.resource_groups += [$rg]')
done

# ---------------------------------------------------------------------------
# 3) Discover Enterprise-Configured DNS Servers (the smart part!)
# ---------------------------------------------------------------------------
echo "Discovering enterprise-configured DNS servers..."
dns_resolvers=()

for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" ]]; then
    echo "Analyzing DNS configuration in RG: $rg"
    
    # Find Azure DNS Private Resolvers and their inbound endpoints
    resolver_list=$(az network dns-resolver list --resource-group "$rg" --query "[?provisioningState=='Succeeded'].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$resolver_list" ]]; then
      while IFS= read -r resolver_name; do
        if [[ -n "$resolver_name" ]]; then
          echo "  Found DNS Private Resolver: $resolver_name"
          # Get inbound endpoint IPs
          inbound_ips=$(az network dns-resolver inbound-endpoint list --dns-resolver-name "$resolver_name" --resource-group "$rg" --query "[?provisioningState=='Succeeded'].ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || echo "")
          if [[ -n "$inbound_ips" ]]; then
            while IFS= read -r ip; do
              if [[ -n "$ip" && "$ip" != "null" ]]; then
                echo "    Inbound endpoint IP: $ip"
                dns_resolvers+=("$ip")
              fi
            done <<< "$inbound_ips"
          fi
        fi
      done <<< "$resolver_list"
    fi
    
    # Find VNets with custom DNS servers configured
    vnet_dns=$(az network vnet list --resource-group "$rg" --query "[?dhcpOptions.dnsServers != null].{name:name,dns:dhcpOptions.dnsServers}" -o json 2>/dev/null || echo "[]")
    if [[ "$vnet_dns" != "[]" && "$vnet_dns" != "" ]]; then
      echo "  Found VNets with custom DNS configuration:"
      echo "$vnet_dns" | jq -r '.[] | "    VNet: " + .name + " DNS: " + (.dns | join(","))'
      
      # Extract DNS server IPs
      custom_dns=$(echo "$vnet_dns" | jq -r '.[].dns[]' 2>/dev/null || echo "")
      if [[ -n "$custom_dns" ]]; then
        while IFS= read -r dns_ip; do
          if [[ -n "$dns_ip" && "$dns_ip" != "null" ]]; then
            dns_resolvers+=("$dns_ip")
          fi
        done <<< "$custom_dns"
      fi
    fi
  fi
done

# Remove duplicates from DNS resolvers
unique_dns_resolvers=($(printf "%s\n" "${dns_resolvers[@]}" | sort -u))

# If no enterprise DNS resolvers found, add Azure DNS as fallback
if [[ ${#unique_dns_resolvers[@]} -eq 0 ]]; then
  echo "No enterprise DNS resolvers found. Adding Azure DNS (168.63.129.16) as fallback."
  unique_dns_resolvers=("168.63.129.16")
fi

for resolver in "${unique_dns_resolvers[@]}"; do
  discovery_results=$(echo "$discovery_results" | jq --arg resolver "$resolver" '.discovery.dns_resolvers += [$resolver]')
done

echo "DNS resolvers to use: ${unique_dns_resolvers[*]}"

# ---------------------------------------------------------------------------
# 4) Discover Private DNS Zones with meaningful records
# ---------------------------------------------------------------------------
echo "Discovering private DNS zones with actual records..."
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
          
          echo "  Analyzing private zone: $zone"
          
          # Get actual A and CNAME records (not just count)
          a_records=$(az network private-dns record-set a list --resource-group "$rg" --zone-name "$zone" --query "[?name!='@'].name" -o tsv 2>/dev/null || echo "")
          cname_records=$(az network private-dns record-set cname list --resource-group "$rg" --zone-name "$zone" --query "[].name" -o tsv 2>/dev/null || echo "")
          
          # Combine records and suggest meaningful FQDNs
          all_records=$(echo -e "$a_records\n$cname_records" | grep -v '^$' | head -5)  # Limit to 5 per zone
          
          if [[ -n "$all_records" ]]; then
            while IFS= read -r record; do
              if [[ -n "$record" ]]; then
                fqdn="$record.$zone"
                suggested_fqdns+=("$fqdn")
                echo "    Found record: $fqdn"
              fi
            done <<< "$all_records"
          fi
        fi
      done <<< "$zones"
    fi
  fi
done

echo "Found ${#private_zones[@]} private DNS zones"

# ---------------------------------------------------------------------------
# 5) Discover Public DNS Zones
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
          echo "  Found public zone: $zone"
          
          # Add root domain as test FQDN
          suggested_fqdns+=("$zone")
        fi
      done <<< "$zones"
    fi
  fi
done

echo "Found ${#public_zones[@]} public DNS zones"

# ---------------------------------------------------------------------------
# 6) Smart Forward Lookup Zone Detection
# ---------------------------------------------------------------------------
echo "Detecting forward lookup zones..."
forward_zones=()

# Look for DNS forwarding rulesets (these indicate forward lookup zones)
for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" ]]; then
    # Check for DNS forwarding rulesets
    forwarding_rulesets=$(az network dns-resolver forwarding-ruleset list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$forwarding_rulesets" ]]; then
      while IFS= read -r ruleset; do
        if [[ -n "$ruleset" ]]; then
          echo "  Found DNS forwarding ruleset: $ruleset"
          # Get forwarding rules to find target domains
          rules=$(az network dns-resolver forwarding-rule list --dns-forwarding-ruleset-name "$ruleset" --resource-group "$rg" --query "[].{domain:domainName,state:forwardingRuleState}" -o json 2>/dev/null || echo "[]")
          if [[ "$rules" != "[]" ]]; then
            domains=$(echo "$rules" | jq -r '.[] | select(.state=="Enabled") | .domain' 2>/dev/null || echo "")
            if [[ -n "$domains" ]]; then
              while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                  forward_zones+=("$domain")
                  discovery_results=$(echo "$discovery_results" | jq --arg zone "$domain" '.discovery.forward_lookup_zones += [$zone]')
                  echo "    Forward lookup zone: $domain"
                fi
              done <<< "$domains"
            fi
          fi
        fi
      done <<< "$forwarding_rulesets"
    fi
  fi
done

echo "Found ${#forward_zones[@]} forward lookup zones"

# ---------------------------------------------------------------------------
# 7) Express Route Zone Detection
# ---------------------------------------------------------------------------
echo "Detecting Express Route related zones..."
express_route_zones=()

# Look for private zones with records pointing to on-premises IP ranges
for zone in "${private_zones[@]}"; do
  for rg in "${rg_array[@]}"; do
    if [[ -n "$rg" ]]; then
      # Check A records for on-premises IP patterns
      on_prem_ips=$(az network private-dns record-set a list --resource-group "$rg" --zone-name "$zone" --query "[].aRecords[].ipv4Address" -o tsv 2>/dev/null || echo "")
      
      if [[ -n "$on_prem_ips" ]]; then
        has_on_prem=false
        while IFS= read -r ip; do
          # Check for common on-premises IP ranges (10.x, 172.16-31.x, 192.168.x)
          if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
            has_on_prem=true
            break
          fi
        done <<< "$on_prem_ips"
        
        if [[ "$has_on_prem" == "true" ]]; then
          if [[ ! " ${express_route_zones[*]} " =~ " $zone " ]]; then
            express_route_zones+=("$zone")
            discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.express_route_zones += [$zone]')
            echo "  Express Route zone: $zone (has on-premises IPs)"
          fi
        fi
      fi
    fi
  done
done

echo "Found ${#express_route_zones[@]} Express Route zones"

# ---------------------------------------------------------------------------
# 8) Finalize suggested test FQDNs
# ---------------------------------------------------------------------------
# Remove duplicates and limit to reasonable number
unique_fqdns=($(printf '%s\n' "${suggested_fqdns[@]}" | sort -u | head -10))

for fqdn in "${unique_fqdns[@]}"; do
  discovery_results=$(echo "$discovery_results" | jq --arg fqdn "$fqdn" '.discovery.suggested_test_fqdns += [$fqdn]')
done

# ---------------------------------------------------------------------------
# 9) Output results
# ---------------------------------------------------------------------------
echo "$discovery_results" | jq . > "$OUTPUT_FILE"

echo ""
echo "=== Smart Discovery Complete ==="
echo "Results saved to: $OUTPUT_FILE"
echo ""
echo "Summary:"
echo "- Resource Groups: ${#rg_array[@]}"
echo "- Enterprise DNS Resolvers: ${#unique_dns_resolvers[@]}"
echo "- Private DNS Zones: ${#private_zones[@]}"
echo "- Public DNS Zones: ${#public_zones[@]}"
echo "- Suggested Test FQDNs: ${#unique_fqdns[@]}"
echo "- Forward Lookup Zones: ${#forward_zones[@]}"
echo "- Express Route Zones: ${#express_route_zones[@]}"
echo ""
if [[ ${#unique_dns_resolvers[@]} -gt 0 ]]; then
  echo "Enterprise DNS Resolvers Found:"
  for resolver in "${unique_dns_resolvers[@]}"; do
    echo "  $resolver (Enterprise-configured)"
  done
else
  echo "No enterprise DNS resolvers found. Using default Azure DNS (168.63.129.16) as fallback."
fi
