#!/bin/bash

# Validation script for repository performance test scenarios
# This script validates that performance issues are properly detected

set -e

PROJECT_NAME="${project_name}"
ORG_URL="${org_url}"

echo "=== Validating Performance Test Scenarios ==="
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

# Validate large repository test
echo "1. Validating Large Repository Test"
validate_test_result \
    "Large Repository" \
    "output/large-repo" \
    "Repository Size Exceeds Threshold" \
    "Large Repository May Need Git LFS"

# Validate excessive branches test
echo "2. Validating Excessive Branches Test"
validate_test_result \
    "Excessive Branches Repository" \
    "output/excessive-branches" \
    "Excessive Number of Branches" \
    "Stale Branches Detected"

# Validate frequent pushes test
echo "3. Validating Frequent Pushes Test"
validate_test_result \
    "Frequent Pushes Repository" \
    "output/frequent-pushes" \
    "High Frequency of Small Commits" \
    "Workflow Efficiency Issues"

# Check for repository size analysis
echo "4. Validating Repository Size Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Repository Size Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Repository size analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Repository size analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for branch management analysis
echo "5. Validating Branch Management Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Branch Management Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Branch management analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Branch management analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for performance metrics
echo "6. Validating Performance Metrics"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Performance Score" "$test_dir/log.html" 2>/dev/null; then
            score=$(grep -o "Performance Score: [0-9]*" "$test_dir/log.html" | grep -o "[0-9]*" || echo "unknown")
            echo -e "${GREEN}✓ Performance score calculated for $test_name: $score${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Performance score not found for $test_name${NC}"
        fi
    fi
done

# Check for Git LFS recommendations
echo "7. Validating Git LFS Recommendations"
if [ -d "output/large-repo" ]; then
    if grep -q "Git LFS" "output/large-repo/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Git LFS recommendations provided for large repository${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${YELLOW}⚠ Git LFS recommendations not found for large repository${NC}"
    fi
fi

# Check for branch cleanup recommendations
echo "8. Validating Branch Cleanup Recommendations"
if [ -d "output/excessive-branches" ]; then
    if grep -q "Branch Cleanup" "output/excessive-branches/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Branch cleanup recommendations provided${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${YELLOW}⚠ Branch cleanup recommendations not found${NC}"
    fi
fi

# Check for commit pattern analysis
echo "9. Validating Commit Pattern Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Commit Pattern Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Commit pattern analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Commit pattern analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for optimization recommendations
echo "10. Validating Optimization Recommendations"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Optimization Recommendations" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Optimization recommendations provided for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Optimization recommendations not found for $test_name${NC}"
        fi
    fi
done

# Summary
echo "=== Performance Test Validation Summary ==="
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All performance tests validated successfully!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some performance tests failed validation${NC}"
    echo "Review the output above and check test configurations"
    exit 1
fi 