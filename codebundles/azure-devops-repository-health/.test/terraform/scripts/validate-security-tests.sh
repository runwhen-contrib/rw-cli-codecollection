#!/bin/bash

# Validation script for repository security test scenarios
# This script validates that security issues are properly detected

set -e

PROJECT_NAME="${project_name}"
ORG_URL="${org_url}"

echo "=== Validating Security Test Scenarios ==="
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

# Validate unprotected repository test
echo "1. Validating Unprotected Repository Test"
validate_test_result \
    "Unprotected Repository" \
    "output/unprotected-repo" \
    "Missing Required Reviewers Policy" \
    "Missing Build Validation Policy" \
    "Unprotected Default Branch"

# Validate weak security test
echo "2. Validating Weak Security Test"
validate_test_result \
    "Weak Security Configuration" \
    "output/weak-security" \
    "Insufficient Required Reviewers" \
    "Creator Can Approve Own Changes" \
    "Reviews Not Reset on New Changes"

# Validate overpermissioned repository test
echo "3. Validating Over-Permissioned Repository Test"
validate_test_result \
    "Over-Permissioned Repository" \
    "output/overpermissioned" \
    "Excessive Repository Permissions" \
    "Public Read Access Enabled"

# Check for critical investigation triggers
echo "4. Validating Critical Investigation Triggers"
if [ -d "output/unprotected-repo" ]; then
    if grep -q "Critical repository investigation" "output/unprotected-repo/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Critical investigation triggered for unprotected repository${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ Critical investigation not triggered for unprotected repository${NC}"
        ((TESTS_FAILED++))
    fi
fi

# Check health scores
echo "5. Validating Health Scores"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Repository Health Score" "$test_dir/log.html" 2>/dev/null; then
            score=$(grep -o "Repository Health Score: [0-9]*" "$test_dir/log.html" | grep -o "[0-9]*" || echo "unknown")
            echo -e "${GREEN}✓ Health score calculated for $test_name: $score${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Health score not found for $test_name${NC}"
        fi
    fi
done

# Summary
echo "=== Security Test Validation Summary ==="
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All security tests validated successfully!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some security tests failed validation${NC}"
    echo "Review the output above and check test configurations"
    exit 1
fi 