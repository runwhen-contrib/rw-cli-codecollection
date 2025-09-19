#!/bin/bash

# Run All Tests Script
# This script runs all tests and provides a comprehensive test report

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CONFIGS_DIR="$SCRIPT_DIR/configs"
DOCS_DIR="$SCRIPT_DIR/docs"

# Function to print header
print_header() {
    local title=$1
    echo -e "${PURPLE}========================================${NC}"
    echo -e "${PURPLE}${title}${NC}"
    echo -e "${PURPLE}========================================${NC}"
    echo
}

# Function to print section
print_section() {
    local title=$1
    echo -e "${CYAN}--- ${title} ---${NC}"
    echo
}

# Function to run DNS resolution test
run_dns_test() {
    print_section "DNS Resolution Test"
    if [ -f "$SCRIPTS_DIR/test-dns-resolution.sh" ]; then
        "$SCRIPTS_DIR/test-dns-resolution.sh"
    else
        echo -e "${RED}DNS resolution test script not found${NC}"
    fi
    echo
}

# Function to run Azure DNS test
run_azure_test() {
    print_section "Azure DNS Test"
    if [ -f "$SCRIPTS_DIR/test-azure-dns.sh" ]; then
        "$SCRIPTS_DIR/test-azure-dns.sh"
    else
        echo -e "${RED}Azure DNS test script not found${NC}"
    fi
    echo
}

# Function to run configuration tests
run_config_tests() {
    print_section "Configuration Tests"
    if [ -f "$SCRIPTS_DIR/run-tests.sh" ]; then
        "$SCRIPTS_DIR/run-tests.sh" --all
    else
        echo -e "${RED}Configuration test script not found${NC}"
    fi
    echo
}

# Function to show test summary
show_test_summary() {
    print_section "Test Summary"
    
    echo -e "${YELLOW}Test Directory Structure:${NC}"
    find "$SCRIPT_DIR" -type f -name "*.sh" -o -name "*.yaml" -o -name "*.txt" -o -name "*.md" | sort | while read -r file; do
        local rel_path="${file#$SCRIPT_DIR/}"
        echo -e "${BLUE}  ${rel_path}${NC}"
    done
    echo
    
    echo -e "${YELLOW}Available Test Configurations:${NC}"
    find "$CONFIGS_DIR" -name "*.yaml" -type f -exec basename {} .yaml \; | sort | while read -r test; do
        echo -e "${BLUE}  - ${test}${NC}"
    done
    echo
    
    echo -e "${YELLOW}Available Test Scripts:${NC}"
    find "$SCRIPTS_DIR" -name "*.sh" -type f -exec basename {} \; | sort | while read -r script; do
        echo -e "${BLUE}  - ${script}${NC}"
    done
    echo
    
    echo -e "${YELLOW}Sample Data Files:${NC}"
    find "$SCRIPT_DIR/sample-data" -name "*.txt" -type f -exec basename {} \; | sort | while read -r data; do
        echo -e "${BLUE}  - ${data}${NC}"
    done
    echo
}

# Function to show usage information
show_usage() {
    echo -e "${YELLOW}Azure DNS Health Test Runner${NC}"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  -s, --summary        Show test summary only"
    echo "  -d, --dns-only       Run DNS resolution tests only"
    echo "  -a, --azure-only     Run Azure DNS tests only"
    echo "  -c, --config-only    Run configuration tests only"
    echo "  -f, --full           Run all tests (default)"
    echo
    echo "Examples:"
    echo "  $0                   # Run all tests"
    echo "  $0 --full            # Run all tests"
    echo "  $0 --dns-only        # Run DNS resolution tests only"
    echo "  $0 --azure-only      # Run Azure DNS tests only"
    echo "  $0 --config-only     # Run configuration tests only"
    echo "  $0 --summary         # Show test summary only"
    echo
}

# Function to run full test suite
run_full_tests() {
    print_header "Azure DNS Health Test Suite"
    
    # Check prerequisites
    print_section "Prerequisites Check"
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check if Azure CLI is available
    if command -v az >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Azure CLI is available${NC}"
    else
        echo -e "${RED}✗ Azure CLI not found${NC}"
        echo -e "${YELLOW}Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli${NC}"
    fi
    
    # Check if nslookup is available
    if command -v nslookup >/dev/null 2>&1; then
        echo -e "${GREEN}✓ nslookup is available${NC}"
    else
        echo -e "${RED}✗ nslookup not found${NC}"
        echo -e "${YELLOW}Please install DNS utilities${NC}"
    fi
    
    # Check if jq is available
    if command -v jq >/dev/null 2>&1; then
        echo -e "${GREEN}✓ jq is available${NC}"
    else
        echo -e "${RED}✗ jq not found${NC}"
        echo -e "${YELLOW}Please install jq: https://stedolan.github.io/jq/${NC}"
    fi
    
    echo
    
    # Run DNS resolution test
    run_dns_test
    
    # Run Azure DNS test
    run_azure_test
    
    # Run configuration tests
    run_config_tests
    
    print_section "Test Complete"
    echo -e "${GREEN}All tests completed successfully!${NC}"
    echo
}

# Main function
main() {
    case "${1:-}" in
        -h|--help)
            show_usage
            ;;
        -s|--summary)
            show_test_summary
            ;;
        -d|--dns-only)
            print_header "DNS Resolution Tests"
            run_dns_test
            ;;
        -a|--azure-only)
            print_header "Azure DNS Tests"
            run_azure_test
            ;;
        -c|--config-only)
            print_header "Configuration Tests"
            run_config_tests
            ;;
        -f|--full|"")
            run_full_tests
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
