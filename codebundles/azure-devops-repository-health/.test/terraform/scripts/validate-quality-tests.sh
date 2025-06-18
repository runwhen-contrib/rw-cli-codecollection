#!/bin/bash

# Validation script for repository code quality test scenarios
# This script validates that code quality issues are properly detected

set -e

PROJECT_NAME="${project_name}"
ORG_URL="${org_url}"

echo "=== Validating Code Quality Test Scenarios ==="
echo "Project: $PROJECT_NAME"
echo "Organization: $ORG_URL"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0

validate_test_result() {
    local test_name="$1"
    local output_dir="$2"
    local expected_issues=("$${@:3}")
    
    echo "Validating: $test_name"
    
    if [ ! -d "$output_dir" ]; then
        echo -e "${RED}✗ Output directory not found: $output_dir${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
    
    # Check if log file exists
    if [ ! -f "$output_dir/log.html" ]; then
        echo -e "${RED}✗ Log file not found in $output_dir${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
    
    # Check for expected issues in the output
    local issues_found=0
    for issue in "$${expected_issues[@]}"; do
        if grep -q "$issue" "$output_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Found expected issue: $issue${NC}"
            ((issues_found++))
        else
            echo -e "${YELLOW}  ⚠ Expected issue not found: $issue${NC}"
        fi
    done
    
    if [ $issues_found -gt 0 ]; then
        echo -e "${GREEN}✓ $test_name validation passed ($issues_found issues detected)${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ $test_name validation failed (no expected issues detected)${NC}"
        ((TESTS_FAILED++))
    fi
    
    echo ""
}

# Validate no builds repository test
echo "1. Validating No Builds Repository Test"
validate_test_result \
    "No Builds Repository" \
    "output/no-builds" \
    "No Build Definitions Found" \
    "No Test Results Found" \
    "Missing Build Validation Policy"

# Validate failing builds test
echo "2. Validating Failing Builds Test"
validate_test_result \
    "Failing Builds Repository" \
    "output/failing-builds" \
    "High Build Failure Rate" \
    "Recent Build Failures"

# Validate poor structure test
echo "3. Validating Poor Structure Test"
validate_test_result \
    "Poor Structure Repository" \
    "output/poor-structure" \
    "Poor Branch Naming Conventions" \
    "No Standard Workflow Branches"

# Check for build analysis
echo "4. Validating Build Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Build Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Build analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Build analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for code quality metrics
echo "5. Validating Code Quality Metrics"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Code Quality Score" "$test_dir/log.html" 2>/dev/null; then
            score=$(grep -o "Code Quality Score: [0-9]*" "$test_dir/log.html" | grep -o "[0-9]*" || echo "unknown")
            echo -e "${GREEN}✓ Code quality score calculated for $test_name: $score${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Code quality score not found for $test_name${NC}"
        fi
    fi
done

# Check for technical debt analysis
echo "6. Validating Technical Debt Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Technical Debt" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Technical debt analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Technical debt analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for critical investigation triggers for quality issues
echo "7. Validating Critical Investigation for Quality Issues"
if [ -d "output/no-builds" ]; then
    if grep -q "Critical repository investigation" "output/no-builds/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Critical investigation triggered for no builds repository${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ Critical investigation not triggered for no builds repository${NC}"
        ((TESTS_FAILED++))
    fi
fi

# Summary
echo "=== Code Quality Test Validation Summary ==="
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All code quality tests validated successfully!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some code quality tests failed validation${NC}"
    echo "Review the output above and check test configurations"
    exit 1
fi 