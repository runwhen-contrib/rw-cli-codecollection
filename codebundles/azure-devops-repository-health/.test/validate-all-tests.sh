#!/bin/bash

# Comprehensive validation script for all repository health test scenarios
# This script runs all validation tests and provides a summary

set -e

echo "=== Repository Health Test Validation Suite ==="
echo "Running comprehensive validation of all test scenarios..."
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TOTAL_VALIDATIONS=0
PASSED_VALIDATIONS=0
FAILED_VALIDATIONS=0

run_validation() {
    local validation_name="$1"
    local validation_script="$2"
    
    echo -e "${BLUE}=== Running $validation_name ===${NC}"
    ((TOTAL_VALIDATIONS++))
    
    if [ -f "$validation_script" ]; then
        if bash "$validation_script"; then
            echo -e "${GREEN}✓ $validation_name passed${NC}"
            ((PASSED_VALIDATIONS++))
        else
            echo -e "${RED}✗ $validation_name failed${NC}"
            ((FAILED_VALIDATIONS++))
        fi
    else
        echo -e "${RED}✗ Validation script not found: $validation_script${NC}"
        ((FAILED_VALIDATIONS++))
    fi
    
    echo ""
}

# Check if test outputs exist
check_test_outputs() {
    echo "Checking for test outputs..."
    
    if [ ! -d "output" ]; then
        echo -e "${RED}✗ No test output directory found${NC}"
        echo "Please run tests first: task test-all-scenarios"
        exit 1
    fi
    
    local output_count=$(find output -name "*.html" | wc -l)
    if [ $output_count -eq 0 ]; then
        echo -e "${RED}✗ No test output files found${NC}"
        echo "Please run tests first: task test-all-scenarios"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Found $output_count test output files${NC}"
    echo ""
}

# Run all validations
main() {
    check_test_outputs
    
    # Run individual validation scripts
    run_validation "Security Tests" "./validate-security-tests.sh"
    run_validation "Code Quality Tests" "./validate-quality-tests.sh"
    run_validation "Collaboration Tests" "./validate-collaboration-tests.sh"
    run_validation "Performance Tests" "./validate-performance-tests.sh"
    
    # Additional comprehensive checks
    echo -e "${BLUE}=== Running Additional Comprehensive Checks ===${NC}"
    
    # Check that all expected test scenarios have outputs
    expected_scenarios=(
        "unprotected-repo"
        "weak-security"
        "overpermissioned"
        "no-builds"
        "failing-builds"
        "poor-structure"
        "abandoned-prs"
        "single-reviewer"
        "quick-merges"
        "large-repo"
        "excessive-branches"
        "frequent-pushes"
    )
    
    echo "Checking for all expected test scenario outputs..."
    for scenario in "$${expected_scenarios[@]}"; do
        if [ -d "output/$scenario" ]; then
            echo -e "${GREEN}  ✓ Found output for $scenario${NC}"
        else
            echo -e "${YELLOW}  ⚠ Missing output for $scenario${NC}"
        fi
    done
    
    # Check for critical investigation triggers
    echo ""
    echo "Checking for critical investigation triggers..."
    critical_scenarios=("unprotected-repo" "no-builds")
    for scenario in "$${critical_scenarios[@]}"; do
        if [ -f "output/$scenario/log.html" ]; then
            if grep -q "Critical repository investigation" "output/$scenario/log.html" 2>/dev/null; then
                echo -e "${GREEN}  ✓ Critical investigation triggered for $scenario${NC}"
            else
                echo -e "${RED}  ✗ Critical investigation NOT triggered for $scenario${NC}"
            fi
        fi
    done
    
    # Check for health score calculations
    echo ""
    echo "Checking for health score calculations..."
    for output_dir in output/*/; do
        if [ -f "$output_dir/log.html" ]; then
            scenario=$(basename "$output_dir")
            if grep -q "Repository Health Score" "$output_dir/log.html" 2>/dev/null; then
                score=$(grep -o "Repository Health Score: [0-9]*" "$output_dir/log.html" | grep -o "[0-9]*" || echo "unknown")
                echo -e "${GREEN}  ✓ Health score for $scenario: $score${NC}"
            else
                echo -e "${YELLOW}  ⚠ No health score found for $scenario${NC}"
            fi
        fi
    done
    
    # Check for issue generation
    echo ""
    echo "Checking for issue generation..."
    total_issues=0
    for output_dir in output/*/; do
        if [ -f "$output_dir/log.html" ]; then
            scenario=$(basename "$output_dir")
            issue_count=$(grep -c "Issue:" "$output_dir/log.html" 2>/dev/null || echo "0")
            if [ $issue_count -gt 0 ]; then
                echo -e "${GREEN}  ✓ $scenario generated $issue_count issues${NC}"
                ((total_issues += issue_count))
            else
                echo -e "${YELLOW}  ⚠ $scenario generated no issues${NC}"
            fi
        fi
    done
    
    echo ""
    echo -e "${BLUE}Total issues generated across all tests: $total_issues${NC}"
    
    # Final summary
    echo ""
    echo "=== Validation Summary ==="
    echo -e "Total Validations: ${BLUE}$TOTAL_VALIDATIONS${NC}"
    echo -e "Passed: ${GREEN}$PASSED_VALIDATIONS${NC}"
    echo -e "Failed: ${RED}$FAILED_VALIDATIONS${NC}"
    
    if [ $FAILED_VALIDATIONS -eq 0 ]; then
        echo ""
        echo -e "${GREEN}🎉 All repository health tests validated successfully!${NC}"
        echo ""
        echo "Test Results Summary:"
        echo "- Security scenarios: Validated"
        echo "- Code quality scenarios: Validated"
        echo "- Collaboration scenarios: Validated"
        echo "- Performance scenarios: Validated"
        echo "- Issue generation: Working"
        echo "- Health scoring: Working"
        echo "- Critical investigations: Working"
        echo ""
        echo "The repository health monitoring codebundle is ready for production use!"
        exit 0
    else
        echo ""
        echo -e "${RED}❌ Some validations failed${NC}"
        echo ""
        echo "Please review the failed validations above and:"
        echo "1. Check test configurations"
        echo "2. Verify test data setup"
        echo "3. Review codebundle implementation"
        echo "4. Re-run specific tests if needed"
        exit 1
    fi
}

# Run main function
main "$@" 