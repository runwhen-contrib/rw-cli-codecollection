#!/bin/bash

# Test script specifically for validating issue generation and values
# This script tests the core functionality of the repository health monitoring

set -e

echo "=== Repository Health Issue Generation Test ==="
echo "Testing issue detection, severity assignment, and value calculations..."
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_REPO="test-unprotected-repo"  # Use the most problematic repo for comprehensive testing
OUTPUT_DIR="output/issue-generation-test"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${BLUE}Running repository health analysis on $TEST_REPO...${NC}"

# Run the repository health runbook with detailed output
cd ../..
robot -v AZURE_DEVOPS_REPO:"$TEST_REPO" \
      -v AZURE_DEVOPS_PROJECT:$(cd .test && source terraform/tf.secret && cd terraform && terraform output -raw project_name 2>/dev/null || echo "test-project") \
      -v AZURE_DEVOPS_ORG:$(cd .test && source terraform/tf.secret && cd terraform && terraform output -raw devops_org 2>/dev/null || echo "test-org") \
      -v AZURE_RESOURCE_GROUP:$(cd .test && source terraform/tf.secret && cd terraform && terraform output -raw resource_group_name 2>/dev/null || echo "test-rg") \
      -d ".test/$OUTPUT_DIR" \
      runbook.robot

cd .test

echo ""
echo -e "${BLUE}Analyzing generated issues and values...${NC}"

# Check if output files exist
if [ ! -f "$OUTPUT_DIR/log.html" ]; then
    echo -e "${RED}✗ Test output not found${NC}"
    exit 1
fi

# Extract and analyze issues
echo "=== Issue Analysis ==="

# Count total issues
total_issues=$(grep -c "Issue:" "$OUTPUT_DIR/log.html" 2>/dev/null || echo "0")
echo "Total issues detected: $total_issues"

if [ $total_issues -eq 0 ]; then
    echo -e "${RED}✗ No issues detected - this indicates a problem with issue generation${NC}"
    exit 1
fi

# Analyze issue severities
echo ""
echo "Issue Severity Distribution:"
for severity in 1 2 3 4; do
    count=$(grep -c "Severity: $severity" "$OUTPUT_DIR/log.html" 2>/dev/null || echo "0")
    echo "  Severity $severity: $count issues"
done

# Check for specific expected issues in unprotected repository
echo ""
echo "=== Expected Issue Validation ==="

expected_issues=(
    "Missing Required Reviewers Policy"
    "Missing Build Validation Policy"
    "Unprotected Default Branch"
    "No Branch Protection Policies"
    "Repository Security Risk"
)

issues_found=0
for issue in "$${expected_issues[@]}"; do
    if grep -q "$issue" "$OUTPUT_DIR/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Found: $issue${NC}"
        ((issues_found++))
    else
        echo -e "${YELLOW}⚠ Not found: $issue${NC}"
    fi
done

echo ""
echo "Expected issues found: $issues_found/${#expected_issues[@]}"

# Check health score calculation
echo ""
echo "=== Health Score Analysis ==="

if grep -q "Repository Health Score" "$OUTPUT_DIR/log.html" 2>/dev/null; then
    health_score=$(grep -o "Repository Health Score: [0-9]*" "$OUTPUT_DIR/log.html" | grep -o "[0-9]*" || echo "unknown")
    echo -e "${GREEN}✓ Health score calculated: $health_score${NC}"
    
    # Validate score is reasonable for unprotected repo (should be low)
    if [ "$health_score" != "unknown" ] && [ "$health_score" -lt 50 ]; then
        echo -e "${GREEN}✓ Health score appropriately low for unprotected repository${NC}"
    elif [ "$health_score" != "unknown" ] && [ "$health_score" -ge 50 ]; then
        echo -e "${YELLOW}⚠ Health score seems high for unprotected repository: $health_score${NC}"
    fi
else
    echo -e "${RED}✗ Health score not calculated${NC}"
fi

# Check for critical investigation trigger
echo ""
echo "=== Critical Investigation Analysis ==="

if grep -q "Critical repository investigation" "$OUTPUT_DIR/log.html" 2>/dev/null; then
    echo -e "${GREEN}✓ Critical investigation triggered${NC}"
    
    # Check if investigation script was executed
    if grep -q "critical-repository-investigation.sh" "$OUTPUT_DIR/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Critical investigation script executed${NC}"
    else
        echo -e "${YELLOW}⚠ Critical investigation script execution not confirmed${NC}"
    fi
else
    echo -e "${RED}✗ Critical investigation not triggered${NC}"
fi

# Check for remediation recommendations
echo ""
echo "=== Remediation Analysis ==="

remediation_topics=(
    "Branch Protection"
    "Required Reviewers"
    "Build Validation"
    "Security Configuration"
    "Policy Implementation"
)

remediation_found=0
for topic in "$${remediation_topics[@]}"; do
    if grep -q "$topic" "$OUTPUT_DIR/log.html" 2>/dev/null; then
        echo -e "${GREEN}✓ Remediation guidance for: $topic${NC}"
        ((remediation_found++))
    else
        echo -e "${YELLOW}⚠ No remediation guidance for: $topic${NC}"
    fi
done

echo ""
echo "Remediation topics covered: $remediation_found/${#remediation_topics[@]}"

# Check for JSON output structure (for integration)
echo ""
echo "=== JSON Output Analysis ==="

if grep -q '"issues":' "$OUTPUT_DIR/log.html" 2>/dev/null; then
    echo -e "${GREEN}✓ JSON issue structure found${NC}"
else
    echo -e "${YELLOW}⚠ JSON issue structure not found${NC}"
fi

# Test specific issue values and calculations
echo ""
echo "=== Issue Value Testing ==="

# Test security score calculation
echo "Testing security score calculation..."
if grep -q "Security Score" "$OUTPUT_DIR/log.html" 2>/dev/null; then
    security_score=$(grep -o "Security Score: [0-9]*" "$OUTPUT_DIR/log.html" | grep -o "[0-9]*" || echo "unknown")
    echo "Security Score: $security_score"
    
    if [ "$security_score" != "unknown" ] && [ "$security_score" -lt 30 ]; then
        echo -e "${GREEN}✓ Security score appropriately low for unprotected repository${NC}"
    else
        echo -e "${YELLOW}⚠ Security score may be too high: $security_score${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Security score not found${NC}"
fi

# Test weighted scoring
echo ""
echo "Testing weighted issue scoring..."
if grep -q "Weighted Score" "$OUTPUT_DIR/log.html" 2>/dev/null; then
    echo -e "${GREEN}✓ Weighted scoring implemented${NC}"
else
    echo -e "${YELLOW}⚠ Weighted scoring not found${NC}"
fi

# Performance test - check execution time
echo ""
echo "=== Performance Analysis ==="

if [ -f "$OUTPUT_DIR/log.html" ]; then
    # Extract execution time if available
    if grep -q "Execution time" "$OUTPUT_DIR/log.html" 2>/dev/null; then
        exec_time=$(grep -o "Execution time: [0-9]*" "$OUTPUT_DIR/log.html" | grep -o "[0-9]*" || echo "unknown")
        echo "Execution time: ${exec_time}s"
        
        if [ "$exec_time" != "unknown" ] && [ "$exec_time" -lt 300 ]; then
            echo -e "${GREEN}✓ Execution time acceptable (< 5 minutes)${NC}"
        else
            echo -e "${YELLOW}⚠ Execution time may be too long: ${exec_time}s${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Execution time not recorded${NC}"
    fi
fi

# Final summary
echo ""
echo "=== Issue Generation Test Summary ==="

# Calculate overall test score
test_score=0
max_score=10

# Scoring criteria
[ $total_issues -gt 0 ] && ((test_score++))
[ $issues_found -gt 2 ] && ((test_score++))
[ "$health_score" != "unknown" ] && ((test_score++))
[ "$health_score" != "unknown" ] && [ "$health_score" -lt 50 ] && ((test_score++))
grep -q "Critical repository investigation" "$OUTPUT_DIR/log.html" 2>/dev/null && ((test_score++))
[ $remediation_found -gt 2 ] && ((test_score++))
grep -q '"issues":' "$OUTPUT_DIR/log.html" 2>/dev/null && ((test_score++))
grep -q "Security Score" "$OUTPUT_DIR/log.html" 2>/dev/null && ((test_score++))
grep -q "Weighted Score" "$OUTPUT_DIR/log.html" 2>/dev/null && ((test_score++))
[ "$exec_time" != "unknown" ] && [ "$exec_time" -lt 300 ] && ((test_score++))

echo "Test Score: $test_score/$max_score"

if [ $test_score -ge 8 ]; then
    echo -e "${GREEN}✓ Issue generation test PASSED${NC}"
    echo ""
    echo "Key Achievements:"
    echo "- Issues are being detected correctly"
    echo "- Health scores are calculated appropriately"
    echo "- Critical investigations trigger when needed"
    echo "- Remediation guidance is provided"
    echo "- Performance is acceptable"
    exit 0
elif [ $test_score -ge 6 ]; then
    echo -e "${YELLOW}⚠ Issue generation test PARTIALLY PASSED${NC}"
    echo ""
    echo "Some functionality is working, but improvements needed."
    echo "Review the analysis above for specific areas to address."
    exit 1
else
    echo -e "${RED}✗ Issue generation test FAILED${NC}"
    echo ""
    echo "Significant issues with the repository health monitoring."
    echo "Review the implementation and test configuration."
    exit 1
fi 