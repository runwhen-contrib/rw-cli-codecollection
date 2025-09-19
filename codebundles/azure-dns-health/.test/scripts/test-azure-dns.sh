#!/bin/bash

# Test Azure DNS Script
# This script tests Azure DNS zones and records

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to test Azure CLI authentication
test_azure_auth() {
    echo -e "${YELLOW}Testing Azure CLI authentication...${NC}"
    if az account show >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Azure CLI authenticated${NC}"
        local subscription=$(az account show --query name -o tsv)
        echo -e "${BLUE}Current subscription: ${subscription}${NC}"
        return 0
    else
        echo -e "${RED}✗ Azure CLI not authenticated${NC}"
        echo -e "${YELLOW}Please run: az login${NC}"
        return 1
    fi
}

# Function to test resource groups
test_resource_groups() {
    local resource_groups=$1
    echo -e "${YELLOW}Testing resource groups: ${resource_groups}${NC}"
    
    IFS=',' read -ra RGS <<< "$resource_groups"
    for rg in "${RGS[@]}"; do
        rg=$(echo "$rg" | xargs) # trim whitespace
        if [ -n "$rg" ]; then
            echo -e "${YELLOW}Checking resource group: ${rg}${NC}"
            if az group show --name "$rg" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Resource group ${rg} exists${NC}"
            else
                echo -e "${RED}✗ Resource group ${rg} not found${NC}"
            fi
        fi
    done
}

# Function to test private DNS zones
test_private_dns_zones() {
    local resource_groups=$1
    echo -e "${YELLOW}Testing private DNS zones...${NC}"
    
    IFS=',' read -ra RGS <<< "$resource_groups"
    for rg in "${RGS[@]}"; do
        rg=$(echo "$rg" | xargs) # trim whitespace
        if [ -n "$rg" ]; then
            echo -e "${YELLOW}Checking private DNS zones in ${rg}...${NC}"
            local zones=$(az network private-dns zone list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
            if [ -n "$zones" ]; then
                echo -e "${GREEN}✓ Found private DNS zones in ${rg}:${NC}"
                echo "$zones" | while read -r zone; do
                    echo -e "${BLUE}  - ${zone}${NC}"
                done
            else
                echo -e "${YELLOW}  No private DNS zones found in ${rg}${NC}"
            fi
        fi
    done
}

# Function to test public DNS zones
test_public_dns_zones() {
    local resource_groups=$1
    echo -e "${YELLOW}Testing public DNS zones...${NC}"
    
    IFS=',' read -ra RGS <<< "$resource_groups"
    for rg in "${RGS[@]}"; do
        rg=$(echo "$rg" | xargs) # trim whitespace
        if [ -n "$rg" ]; then
            echo -e "${YELLOW}Checking public DNS zones in ${rg}...${NC}"
            local zones=$(az network dns zone list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
            if [ -n "$zones" ]; then
                echo -e "${GREEN}✓ Found public DNS zones in ${rg}:${NC}"
                echo "$zones" | while read -r zone; do
                    echo -e "${BLUE}  - ${zone}${NC}"
                done
            else
                echo -e "${YELLOW}  No public DNS zones found in ${rg}${NC}"
            fi
        fi
    done
}

# Function to test VNets
test_vnets() {
    local resource_groups=$1
    echo -e "${YELLOW}Testing VNets...${NC}"
    
    IFS=',' read -ra RGS <<< "$resource_groups"
    for rg in "${RGS[@]}"; do
        rg=$(echo "$rg" | xargs) # trim whitespace
        if [ -n "$rg" ]; then
            echo -e "${YELLOW}Checking VNets in ${rg}...${NC}"
            local vnets=$(az network vnet list --resource-group "$rg" --query "[].name" -o tsv 2>/dev/null || echo "")
            if [ -n "$vnets" ]; then
                echo -e "${GREEN}✓ Found VNets in ${rg}:${NC}"
                echo "$vnets" | while read -r vnet; do
                    echo -e "${BLUE}  - ${vnet}${NC}"
                done
            else
                echo -e "${YELLOW}  No VNets found in ${rg}${NC}"
            fi
        fi
    done
}

# Main test function
main() {
    echo -e "${YELLOW}=== Azure DNS Test Script ===${NC}"
    echo
    
    # Test Azure authentication
    if ! test_azure_auth; then
        exit 1
    fi
    echo
    
    # Get resource groups from environment or use default
    local resource_groups=${RESOURCE_GROUPS:-"production-rg,network-rg"}
    echo -e "${YELLOW}Using resource groups: ${resource_groups}${NC}"
    echo
    
    # Test resource groups
    test_resource_groups "$resource_groups"
    echo
    
    # Test private DNS zones
    test_private_dns_zones "$resource_groups"
    echo
    
    # Test public DNS zones
    test_public_dns_zones "$resource_groups"
    echo
    
    # Test VNets
    test_vnets "$resource_groups"
    echo
    
    echo -e "${GREEN}=== Azure DNS Test Complete ===${NC}"
}

# Run main function
main "$@"
