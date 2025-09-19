#!/bin/bash

# Test DNS Resolution Script
# This script tests DNS resolution for the configured FQDNs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to test DNS resolution
test_dns_resolution() {
    local fqdn=$1
    local resolver=${2:-""}
    
    echo -e "${YELLOW}Testing DNS resolution for: ${fqdn}${NC}"
    if [ -n "$resolver" ]; then
        echo -e "${YELLOW}Using resolver: ${resolver}${NC}"
        if nslookup "$fqdn" "$resolver" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ SUCCESS: ${fqdn} resolved via ${resolver}${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED: ${fqdn} failed to resolve via ${resolver}${NC}"
            return 1
        fi
    else
        if nslookup "$fqdn" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ SUCCESS: ${fqdn} resolved via default resolver${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED: ${fqdn} failed to resolve via default resolver${NC}"
            return 1
        fi
    fi
}

# Function to test DNS latency
test_dns_latency() {
    local fqdn=$1
    local resolver=${2:-""}
    
    echo -e "${YELLOW}Testing DNS latency for: ${fqdn}${NC}"
    if [ -n "$resolver" ]; then
        echo -e "${YELLOW}Using resolver: ${resolver}${NC}"
        local start_time=$(date +%s.%N)
        if nslookup "$fqdn" "$resolver" >/dev/null 2>&1; then
            local end_time=$(date +%s.%N)
            local latency=$(echo "$end_time - $start_time" | bc)
            echo -e "${GREEN}✓ SUCCESS: ${fqdn} resolved via ${resolver} in ${latency}s${NC}"
        else
            echo -e "${RED}✗ FAILED: ${fqdn} failed to resolve via ${resolver}${NC}"
        fi
    else
        local start_time=$(date +%s.%N)
        if nslookup "$fqdn" >/dev/null 2>&1; then
            local end_time=$(date +%s.%N)
            local latency=$(echo "$end_time - $start_time" | bc)
            echo -e "${GREEN}✓ SUCCESS: ${fqdn} resolved via default resolver in ${latency}s${NC}"
        else
            echo -e "${RED}✗ FAILED: ${fqdn} failed to resolve via default resolver${NC}"
        fi
    fi
}

# Main test function
main() {
    echo -e "${YELLOW}=== DNS Resolution Test Script ===${NC}"
    echo
    
    # Test basic FQDNs
    echo -e "${YELLOW}Testing basic FQDNs...${NC}"
    test_dns_resolution "google.com"
    test_dns_resolution "github.com"
    test_dns_resolution "stackoverflow.com"
    echo
    
    # Test with specific resolvers
    echo -e "${YELLOW}Testing with specific resolvers...${NC}"
    test_dns_resolution "google.com" "8.8.8.8"
    test_dns_resolution "google.com" "1.1.1.1"
    echo
    
    # Test latency
    echo -e "${YELLOW}Testing DNS latency...${NC}"
    test_dns_latency "google.com"
    test_dns_latency "github.com"
    echo
    
    echo -e "${GREEN}=== DNS Resolution Test Complete ===${NC}"
}

# Run main function
main "$@"
