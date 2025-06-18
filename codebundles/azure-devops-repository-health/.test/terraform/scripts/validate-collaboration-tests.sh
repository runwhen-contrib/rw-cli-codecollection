#!/bin/bash

# Validation script for repository collaboration test scenarios
# This script validates that collaboration issues are properly detected

set -e

PROJECT_NAME="${project_name}"
ORG_URL="${org_url}"

echo "=== Validating Collaboration Test Scenarios ==="
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

# Validate abandoned PRs test
echo "1. Validating Abandoned PRs Test"
validate_test_result \
    "Abandoned PRs Repository" \
    "output/abandoned-prs" \
    "High Pull Request Abandonment Rate" \
    "Long-Lived Pull Requests"

# Validate single reviewer test
echo "2. Validating Single Reviewer Test"
validate_test_result \
    "Single Reviewer Repository" \
    "output/single-reviewer" \
    "Single Reviewer Bottleneck" \
    "Review Process Inefficiency"

# Validate quick merges test
echo "3. Validating Quick Merges Test"
validate_test_result \
    "Quick Merges Repository" \
    "output/quick-merges" \
    "High Rate of Quick Merges" \
    "Insufficient Review Time"

# Check for pull request analysis
echo "4. Validating Pull Request Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Pull Request Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Pull request analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Pull request analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for collaboration metrics
echo "5. Validating Collaboration Metrics"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Collaboration Score" "$test_dir/log.html" 2>/dev/null; then
            score=$(grep -o "Collaboration Score: [0-9]*" "$test_dir/log.html" | grep -o "[0-9]*" || echo "unknown")
            echo -e "${GREEN}✓ Collaboration score calculated for $test_name: $score${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Collaboration score not found for $test_name${NC}"
        fi
    fi
done

# Check for reviewer analysis
echo "6. Validating Reviewer Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Reviewer Distribution" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Reviewer analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Reviewer analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for PR pattern analysis
echo "7. Validating PR Pattern Analysis"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "PR Pattern Analysis" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ PR pattern analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ PR pattern analysis not found for $test_name${NC}"
        fi
    fi
done

# Check for workflow efficiency metrics
echo "8. Validating Workflow Efficiency Metrics"
for test_dir in output/*/; do
    if [ -f "$test_dir/log.html" ]; then
        test_name=$(basename "$test_dir")
        if grep -q "Workflow Efficiency" "$test_dir/log.html" 2>/dev/null; then
            echo -e "${GREEN}✓ Workflow efficiency analysis performed for $test_name${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${YELLOW}⚠ Workflow efficiency analysis not found for $test_name${NC}"
        fi
    fi
done

# Summary
echo "=== Collaboration Test Validation Summary ==="
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All collaboration tests validated successfully!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some collaboration tests failed validation${NC}"
    echo "Review the output above and check test configurations"
    exit 1
fi 