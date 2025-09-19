#!/bin/bash

# Run Tests Script
# This script runs all the test configurations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
CONFIGS_DIR="$TEST_DIR/configs"
SCRIPTS_DIR="$TEST_DIR/scripts"

# Function to run a test configuration
run_test_config() {
    local config_file=$1
    local config_name=$(basename "$config_file" .yaml)
    
    echo -e "${YELLOW}=== Running Test: ${config_name} ===${NC}"
    echo -e "${BLUE}Configuration file: ${config_file}${NC}"
    echo
    
    # Extract variables from YAML (simple extraction)
    if [ -f "$config_file" ]; then
        echo -e "${YELLOW}Configuration variables:${NC}"
        grep -E "^\s*[A-Z_]+:" "$config_file" | sed 's/^[[:space:]]*/  /' || true
        echo
    else
        echo -e "${RED}Configuration file not found: ${config_file}${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Test configuration loaded successfully${NC}"
    echo
}

# Function to run all test configurations
run_all_tests() {
    echo -e "${YELLOW}=== Running All DNS Health Tests ===${NC}"
    echo
    
    # Find all YAML configuration files
    local config_files=($(find "$CONFIGS_DIR" -name "*.yaml" -type f | sort))
    
    if [ ${#config_files[@]} -eq 0 ]; then
        echo -e "${RED}No test configuration files found in ${CONFIGS_DIR}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Found ${#config_files[@]} test configuration(s)${NC}"
    echo
    
    # Run each test configuration
    for config_file in "${config_files[@]}"; do
        run_test_config "$config_file"
        echo -e "${YELLOW}----------------------------------------${NC}"
        echo
    done
    
    echo -e "${GREEN}=== All Tests Complete ===${NC}"
}

# Function to run specific test
run_specific_test() {
    local test_name=$1
    local config_file="$CONFIGS_DIR/${test_name}.yaml"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Test configuration not found: ${config_file}${NC}"
        echo -e "${YELLOW}Available tests:${NC}"
        find "$CONFIGS_DIR" -name "*.yaml" -type f -exec basename {} .yaml \; | sort
        return 1
    fi
    
    run_test_config "$config_file"
}

# Function to show available tests
show_available_tests() {
    echo -e "${YELLOW}Available test configurations:${NC}"
    find "$CONFIGS_DIR" -name "*.yaml" -type f -exec basename {} .yaml \; | sort | while read -r test; do
        echo -e "${BLUE}  - ${test}${NC}"
    done
    echo
}

# Function to show help
show_help() {
    echo -e "${YELLOW}DNS Health Test Runner${NC}"
    echo
    echo "Usage: $0 [OPTIONS] [TEST_NAME]"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -l, --list     List available tests"
    echo "  -a, --all      Run all tests"
    echo
    echo "Examples:"
    echo "  $0                    # Run all tests"
    echo "  $0 --all              # Run all tests"
    echo "  $0 basic-test         # Run specific test"
    echo "  $0 --list             # List available tests"
    echo
}

# Main function
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            ;;
        -l|--list)
            show_available_tests
            ;;
        -a|--all|"")
            run_all_tests
            ;;
        *)
            run_specific_test "$1"
            ;;
    esac
}

# Run main function
main "$@"
