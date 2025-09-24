#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  azure_dns_sli_discovery.sh
#
#  PURPOSE:
#    Lightweight DNS resource discovery optimized for SLI performance.
#    Focuses on speed over completeness - gets essential info quickly.
#
#  DIFFERENCES FROM FULL DISCOVERY:
#    - Shorter timeouts (30s vs 300s)
#    - Limits resource enumeration
#    - Focuses on critical FQDNs only
#    - Uses cached results when possible
# ---------------------------------------------------------------------------

set -euo pipefail

OUTPUT_FILE="azure_dns_discovery.json"
SLI_CACHE_MINUTES=60  # Cache results for 1 hour for SLI

echo "=== Azure DNS SLI Auto-Discovery ==="
echo "Fast discovery for SLI metrics..."

# Check if we have recent cached results
if [[ -f "$OUTPUT_FILE" ]]; then
    # Check if cache is recent (less than 1 hour old)
    if find "$OUTPUT_FILE" -mmin -${SLI_CACHE_MINUTES} | grep -q .; then
        echo "Using cached discovery results (less than ${SLI_CACHE_MINUTES} minutes old)"
        exit 0
    fi
fi

# Initialize output with minimal structure
discovery_results='{"discovery": {"resource_groups": [], "private_dns_zones": [], "public_dns_zones": [], "suggested_test_fqdns": [], "forward_lookup_zones": [], "express_route_zones": [], "dns_resolvers": []}}'

# Get subscription quickly
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(timeout 10 az account show --query "id" -o tsv 2>/dev/null || echo "")
  if [[ -z "$subscription" ]]; then
    echo "ERROR: Cannot get Azure subscription quickly. Using empty results."
    echo "$discovery_results" > "$OUTPUT_FILE"
    exit 0
  fi
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
fi

echo "Using subscription: $subscription (SLI mode)"

# Fast resource group discovery (limit scope)
if [[ -n "${RESOURCE_GROUPS:-}" ]]; then
  # User specified resource groups - use them
  IFS=',' read -ra rg_array <<< "$RESOURCE_GROUPS"
  echo "Using specified resource groups: $RESOURCE_GROUPS"
else
  # Quick discovery of RGs with DNS zones (timeout after 20 seconds)
  echo "Quick auto-discovery of resource groups..."
  
  # Get first few RGs with private DNS zones (limit to 3 for SLI speed)
  private_dns_rgs=$(timeout 20 az network private-dns zone list --query "[0:3].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Get first few RGs with public DNS zones (limit to 3 for SLI speed)  
  public_dns_rgs=$(timeout 20 az network dns zone list --query "[0:3].resourceGroup" -o tsv 2>/dev/null | sort -u || echo "")
  
  # Combine and limit to first 3 RGs total
  all_rgs=$(echo -e "$private_dns_rgs\n$public_dns_rgs" | grep -v '^$' | sort -u | head -3 || echo "")
  
  if [[ -z "$all_rgs" ]]; then
    echo "No DNS zones found quickly. Using empty results for SLI."
    echo "$discovery_results" > "$OUTPUT_FILE"
    exit 0
  fi
  
  readarray -t rg_array <<< "$all_rgs"
fi

# Update discovery results with resource groups (limit to first 3)
rg_count=0
for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" && $rg_count -lt 3 ]]; then
    discovery_results=$(echo "$discovery_results" | jq --arg rg "$rg" '.discovery.resource_groups += [$rg]')
    ((rg_count++))
  fi
done

# Quick private DNS zone discovery (limit to first 5 zones total)
echo "Quick private DNS zone discovery..."
suggested_fqdns=()
zone_count=0

for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" && $zone_count -lt 5 ]]; then
    # Get first few zones from this RG
    zones=$(timeout 15 az network private-dns zone list --resource-group "$rg" --query "[0:2].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$zones" ]]; then
      while IFS= read -r zone && [[ $zone_count -lt 5 ]]; do
        if [[ -n "$zone" ]]; then
          discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.private_dns_zones += [$zone]')
          
          # Quick check for important records (limit to 2 per zone)
          records=$(timeout 10 az network private-dns record-set list --resource-group "$rg" --zone-name "$zone" --query "[0:2].name" -o tsv 2>/dev/null || echo "")
          
          if [[ -n "$records" ]]; then
            while IFS= read -r record && [[ ${#suggested_fqdns[@]} -lt 10 ]]; do
              if [[ -n "$record" && "$record" != "@" ]]; then
                # Only suggest FQDNs for critical service patterns
                if [[ "$record" =~ (database|db|api|app|web) ]]; then
                  suggested_fqdns+=("$record.$zone")
                fi
              fi
            done <<< "$records"
          fi
          ((zone_count++))
        fi
      done <<< "$zones"
    fi
  fi
done

# Quick public DNS zone discovery (limit to first 3 zones)
echo "Quick public DNS zone discovery..."
public_zone_count=0

for rg in "${rg_array[@]}"; do
  if [[ -n "$rg" && $public_zone_count -lt 3 ]]; then
    zones=$(timeout 15 az network dns zone list --resource-group "$rg" --query "[0:2].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$zones" ]]; then
      while IFS= read -r zone && [[ $public_zone_count -lt 3 ]]; do
        if [[ -n "$zone" ]]; then
          discovery_results=$(echo "$discovery_results" | jq --arg zone "$zone" '.discovery.public_dns_zones += [$zone]')
          suggested_fqdns+=("$zone")  # Add root domain
          ((public_zone_count++))
        fi
      done <<< "$zones"
    fi
  fi
done

# Add suggested FQDNs to results (limit to first 10)
fqdn_count=0
for fqdn in "${suggested_fqdns[@]}"; do
  if [[ $fqdn_count -lt 10 ]]; then
    discovery_results=$(echo "$discovery_results" | jq --arg fqdn "$fqdn" '.discovery.suggested_test_fqdns += [$fqdn]')
    ((fqdn_count++))
  fi
done

# Output results
echo "$discovery_results" | jq . > "$OUTPUT_FILE"

echo "SLI discovery complete:"
echo "- Resource Groups: ${#rg_array[@]} (max 3)"
echo "- Suggested FQDNs: ${#suggested_fqdns[@]} (max 10)"
echo "- Cache valid for: ${SLI_CACHE_MINUTES} minutes"

echo "Results optimized for SLI speed and cached at: $OUTPUT_FILE"

