#!/bin/bash

# Azure ACR Health Test Infrastructure Cost Calculator
# Estimates monthly costs for different configuration options

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

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cost constants (USD/month, approximate)
BASIC_ACR_COST=5.0
STANDARD_ACR_COST=20.0
PREMIUM_ACR_COST=100.0
LOG_ANALYTICS_BASE_COST=2.30  # ~1GB/month
VNET_COST=3.65
PRIVATE_ENDPOINT_COST=7.30
GEO_REPLICATION_COST=100.0  # Additional Premium region

calculate_cost() {
    local primary_sku="$1"
    local enable_geo_replication="$2"
    local enable_private_endpoint="$3"
    local log_retention_days="$4"
    
    local primary_cost=0
    case "$primary_sku" in
        "Basic")
            primary_cost=$BASIC_ACR_COST
            ;;
        "Standard")
            primary_cost=$STANDARD_ACR_COST
            ;;
        "Premium")
            primary_cost=$PREMIUM_ACR_COST
            ;;
    esac
    
    # Basic ACR is always included
    local basic_cost=$BASIC_ACR_COST
    
    # Log Analytics cost (scales with retention)
    local log_cost=$(echo "scale=2; $LOG_ANALYTICS_BASE_COST * ($log_retention_days / 30)" | bc -l)
    
    # VNet cost (always included)
    local vnet_cost=$VNET_COST
    
    # Optional costs
    local geo_cost=0
    if [[ "$primary_sku" == "Premium" && "$enable_geo_replication" == "true" ]]; then
        geo_cost=$GEO_REPLICATION_COST
    fi
    
    local pe_cost=0
    if [[ "$enable_private_endpoint" == "true" ]]; then
        pe_cost=$PRIVATE_ENDPOINT_COST
    fi
    
    # Calculate total
    local total=$(echo "scale=2; $primary_cost + $basic_cost + $log_cost + $vnet_cost + $geo_cost + $pe_cost" | bc -l)
    
    echo "$total"
}

print_configuration() {
    local config_name="$1"
    local primary_sku="$2"
    local enable_geo_replication="$3"
    local enable_private_endpoint="$4"
    local log_retention_days="$5"
    local color="$6"
    
    local cost=$(calculate_cost "$primary_sku" "$enable_geo_replication" "$enable_private_endpoint" "$log_retention_days")
    
    echo -e "${color}📊 $config_name${NC}"
    echo "   Primary ACR: $primary_sku"
    echo "   Basic ACR: Always included"
    echo "   Log Retention: $log_retention_days days"
    echo "   Geo-replication: $enable_geo_replication"
    echo "   Private Endpoint: $enable_private_endpoint"
    echo -e "   ${color}💰 Estimated Monthly Cost: \$${cost}${NC}"
    echo ""
}

show_terraform_commands() {
    local config_name="$1"
    local primary_sku="$2"
    local enable_geo_replication="$3"
    local enable_private_endpoint="$4"
    local log_retention_days="$5"
    
    echo "Terraform command for $config_name:"
    echo "terraform apply \\"
    echo "  -var=\"primary_acr_sku=$primary_sku\" \\"
    echo "  -var=\"enable_geo_replication=$enable_geo_replication\" \\"
    echo "  -var=\"enable_private_endpoint=$enable_private_endpoint\" \\"
    echo "  -var=\"log_retention_days=$log_retention_days\""
    echo ""
}

echo -e "${BLUE}🏗️  Azure ACR Health Test Infrastructure Cost Calculator${NC}"
echo "=================================================================="
echo ""

# Check if bc is available
if ! command -v bc &> /dev/null; then
    echo -e "${RED}Error: 'bc' calculator is required but not installed.${NC}"
    echo "Install with: apt-get install bc (Ubuntu) or brew install bc (macOS)"
    exit 1
fi

# Configuration options
print_configuration "Ultra Cost-Conscious (Recommended for CI/CD)" "Basic" "false" "false" "30" "$GREEN"
print_configuration "Balanced Testing (Default)" "Standard" "false" "false" "30" "$YELLOW"
print_configuration "Advanced Testing" "Standard" "false" "true" "30" "$YELLOW"
print_configuration "Premium Testing (Full Features)" "Premium" "true" "true" "30" "$RED"

echo -e "${BLUE}💡 Cost Optimization Tips:${NC}"
echo "• Use Basic SKU for simple connectivity/auth testing"
echo "• Use Standard SKU for webhook and retention policy testing"  
echo "• Use Premium SKU only when testing geo-replication or trust policies"
echo "• Keep log retention at minimum 30 days (Azure requirement) for cost savings"
echo "• Disable private endpoint unless testing network isolation"
echo "• Always clean up resources after testing!"
echo ""

echo -e "${BLUE}🚀 Quick Deploy Commands:${NC}"
echo ""

show_terraform_commands "Ultra Cost-Conscious" "Basic" "false" "false" "30"
show_terraform_commands "Balanced Testing" "Standard" "false" "false" "30"
show_terraform_commands "Premium Testing" "Premium" "true" "true" "30"

echo -e "${BLUE}📊 Cost Monitoring:${NC}"
echo "# Check estimated costs after planning:"
echo "terraform output estimated_monthly_cost_usd"
echo ""
echo "# Monitor actual Azure costs:"
echo "az consumption usage list --start-date \$(date -d '1 month ago' +%Y-%m-%d)"
echo ""

echo -e "${RED}⚠️  Remember to clean up resources after testing:${NC}"
echo "task clean  # or terraform destroy"
echo ""

# If terraform is available and we're in the terraform directory, show current config cost
if command -v terraform &> /dev/null && [ -f "main.tf" ]; then
    echo -e "${BLUE}📋 Current Configuration Cost:${NC}"
    if [ -f "terraform.tfstate" ]; then
        terraform output estimated_monthly_cost_usd 2>/dev/null || echo "Run 'terraform refresh' to see current cost estimate"
    else
        echo "No infrastructure currently deployed"
    fi
fi
