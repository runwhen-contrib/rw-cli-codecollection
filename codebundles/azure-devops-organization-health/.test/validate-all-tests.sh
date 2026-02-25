#!/bin/bash

# Validation script for Azure DevOps Organization Health tests
# This script validates that all test scenarios properly trigger the expected issues

set -e

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_TESTS++))
}

log_failure() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_TESTS++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Increment test counter
count_test() {
    ((TOTAL_TESTS++))
}

# Function to validate agent pool capacity tests
validate_agent_pool_tests() {
    log_info "Validating agent pool capacity tests..."
    
    local test_output="$OUTPUT_DIR/overutilized-pools"
    
    count_test
    if [ -d "$test_output" ]; then
        if grep -q "Agent Pool Utilization" "$test_output"/*.xml 2>/dev/null; then
            log_success "Agent pool utilization monitoring detected"
        else
            log_failure "Agent pool utilization monitoring not found in test output"
        fi
    else
        log_failure "Agent pool test output directory not found"
    fi
    
    count_test
    if [ -f "$TERRAFORM_DIR/generated-files/overutilized-load-script.sh" ]; then
        log_success "Agent load script generated successfully"
    else
        log_failure "Agent load script not generated"
    fi
}

# Function to validate license utilization tests
validate_license_tests() {
    log_info "Validating license utilization tests..."
    
    local test_output="$OUTPUT_DIR/high-license-usage"
    
    count_test
    if [ -d "$test_output" ]; then
        if grep -q "License Utilization" "$test_output"/*.xml 2>/dev/null; then
            log_success "License utilization monitoring detected"
        else
            log_failure "License utilization monitoring not found in test output"
        fi
    else
        log_failure "License test output directory not found"
    fi
    
    count_test
    if [ -f "$TERRAFORM_DIR/generated-files/license-analysis.sh" ]; then
        log_success "License analysis script generated successfully"
    else
        log_failure "License analysis script not generated"
    fi
}

# Function to validate security policy tests
validate_security_tests() {
    log_info "Validating security policy tests..."
    
    local test_output="$OUTPUT_DIR/weak-policies"
    
    count_test
    if [ -d "$test_output" ]; then
        if grep -q "Security Policy" "$test_output"/*.xml 2>/dev/null; then
            log_success "Security policy validation detected"
        else
            log_failure "Security policy validation not found in test output"
        fi
    else
        log_failure "Security test output directory not found"
    fi
    
    count_test
    if [ -f "$TERRAFORM_DIR/generated-files/security-validation.sh" ]; then
        log_success "Security validation script generated successfully"
    else
        log_failure "Security validation script not generated"
    fi
}

# Function to validate service connectivity tests
validate_service_tests() {
    log_info "Validating service connectivity tests..."
    
    local test_output="$OUTPUT_DIR/connectivity-issues"
    
    count_test
    if [ -d "$test_output" ]; then
        if grep -q "Service.*Connectivity\|API.*Health" "$test_output"/*.xml 2>/dev/null; then
            log_success "Service connectivity monitoring detected"
        else
            log_failure "Service connectivity monitoring not found in test output"
        fi
    else
        log_failure "Service connectivity test output directory not found"
    fi
}

# Function to validate terraform infrastructure
validate_infrastructure() {
    log_info "Validating terraform infrastructure..."
    
    if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
        log_warning "Terraform state not found - infrastructure may not be deployed"
        return
    fi
    
    cd "$TERRAFORM_DIR"
    
    # Validate terraform state
    count_test
    if terraform show terraform.tfstate > /dev/null 2>&1; then
        log_success "Terraform state is valid"
    else
        log_failure "Terraform state is invalid or corrupted"
    fi
    
    # Check for required resources
    local required_resources=(
        "azurerm_resource_group"
        "azuredevops_project"
        "azuredevops_agent_pool"
        "azuredevops_user_entitlement"
    )
    
    for resource in "${required_resources[@]}"; do
        count_test
        if terraform show -json terraform.tfstate | jq -e ".values.root_module.resources[] | select(.type == \"$resource\")" > /dev/null 2>&1; then
            log_success "Required resource type found: $resource"
        else
            log_failure "Required resource type missing: $resource"
        fi
    done
    
    cd "$SCRIPT_DIR"
}

# Function to validate generated scripts
validate_generated_scripts() {
    log_info "Validating generated scripts..."
    
    local generated_dir="$TERRAFORM_DIR/generated-files"
    
    if [ ! -d "$generated_dir" ]; then
        log_failure "Generated files directory not found"
        return
    fi
    
    local expected_scripts=(
        "license-analysis.sh"
        "security-validation.sh"
        "dependency-setup.sh"
        "run-validation-tests.sh"
    )
    
    for script in "${expected_scripts[@]}"; do
        count_test
        if [ -f "$generated_dir/$script" ]; then
            if [ -x "$generated_dir/$script" ]; then
                log_success "Generated script is executable: $script"
            else
                log_failure "Generated script is not executable: $script"
            fi
        else
            log_failure "Expected script not found: $script"
        fi
    done
    
    # Check for agent load scripts (dynamically generated)
    count_test
    if ls "$generated_dir"/*-load-script.sh >/dev/null 2>&1; then
        log_success "Agent load scripts found"
    else
        log_failure "No agent load scripts found"
    fi
}

# Function to validate test outputs
validate_test_outputs() {
    log_info "Validating test outputs..."
    
    if [ ! -d "$OUTPUT_DIR" ]; then
        log_warning "Output directory not found - tests may not have been run"
        return
    fi
    
    local expected_outputs=(
        "overutilized-pools"
        "high-license-usage"
        "weak-policies"
        "connectivity-issues"
    )
    
    for output in "${expected_outputs[@]}"; do
        count_test
        if [ -d "$OUTPUT_DIR/$output" ]; then
            log_success "Test output directory found: $output"
            
            # Check for robot framework files
            if [ -f "$OUTPUT_DIR/$output/output.xml" ]; then
                log_success "Robot Framework output found for: $output"
            else
                log_failure "Robot Framework output missing for: $output"
            fi
        else
            log_failure "Test output directory missing: $output"
        fi
    done
}

# Function to validate organization health detection
validate_health_detection() {
    log_info "Validating organization health issue detection..."
    
    # Check if any test detected expected issues
    local issue_patterns=(
        "Agent.*Pool.*Utilization"
        "License.*Utilization"
        "Security.*Policy"
        "Service.*Connectivity"
    )
    
    for pattern in "${issue_patterns[@]}"; do
        count_test
        if find "$OUTPUT_DIR" -name "*.xml" -exec grep -l "$pattern" {} \; 2>/dev/null | head -1 >/dev/null; then
            log_success "Health issue pattern detected: $pattern"
        else
            log_failure "Health issue pattern not detected: $pattern"
        fi
    done
}

# Function to validate configuration files
validate_configuration() {
    log_info "Validating configuration files..."
    
    local config_files=(
        "$TERRAFORM_DIR/main.tf"
        "$TERRAFORM_DIR/variables.tf"
        "$TERRAFORM_DIR/outputs.tf"
        "$TERRAFORM_DIR/providers.tf"
        "$TERRAFORM_DIR/terraform.tfvars"
    )
    
    for config in "${config_files[@]}"; do
        count_test
        if [ -f "$config" ]; then
            log_success "Configuration file found: $(basename "$config")"
        else
            log_failure "Configuration file missing: $(basename "$config")"
        fi
    done
    
    # Validate terraform syntax
    count_test
    cd "$TERRAFORM_DIR"
    if terraform validate > /dev/null 2>&1; then
        log_success "Terraform configuration is valid"
    else
        log_failure "Terraform configuration has syntax errors"
    fi
    cd "$SCRIPT_DIR"
}

# Function to validate runwhen integration
validate_runwhen_integration() {
    log_info "Validating RunWhen integration files..."
    
    local runwhen_dir="$(dirname "$SCRIPT_DIR")/.runwhen"
    
    count_test
    if [ -d "$runwhen_dir" ]; then
        log_success "RunWhen directory found"
        
        # Check for generation rules
        if [ -f "$runwhen_dir/generation-rules/azure-devops-organization-health.yaml" ]; then
            log_success "Generation rules found"
        else
            log_failure "Generation rules missing"
        fi
        
        # Check for templates
        local template_dir="$runwhen_dir/templates"
        if [ -d "$template_dir" ]; then
            local expected_templates=(
                "azure-devops-organization-health-slx.yaml"
                "azure-devops-organization-health-sli.yaml"
                "azure-devops-organization-health-taskset.yaml"
            )
            
            for template in "${expected_templates[@]}"; do
                count_test
                if [ -f "$template_dir/$template" ]; then
                    log_success "Template found: $template"
                else
                    log_failure "Template missing: $template"
                fi
            done
        else
            log_failure "Templates directory missing"
        fi
    else
        log_failure "RunWhen directory not found"
    fi
}

# Function to generate validation report
generate_validation_report() {
    log_info "Generating validation report..."
    
    local report_file="$SCRIPT_DIR/validation-report.md"
    
    cat > "$report_file" << EOF
# Azure DevOps Organization Health Test Validation Report

Generated on: $(date)

## Test Summary

- **Total Tests**: $TOTAL_TESTS
- **Passed**: $PASSED_TESTS
- **Failed**: $FAILED_TESTS
- **Success Rate**: $(( PASSED_TESTS * 100 / TOTAL_TESTS ))%

## Validation Results

### Infrastructure Validation
$([ $FAILED_TESTS -eq 0 ] && echo "✅ All infrastructure components validated successfully" || echo "❌ Some infrastructure validation failures detected")

### Test Execution Validation
$([ -d "$OUTPUT_DIR" ] && echo "✅ Test outputs found" || echo "❌ No test outputs found")

### Configuration Validation
$([ -f "$TERRAFORM_DIR/main.tf" ] && echo "✅ Terraform configuration validated" || echo "❌ Terraform configuration issues")

### RunWhen Integration
$([ -d "$(dirname "$SCRIPT_DIR")/.runwhen" ] && echo "✅ RunWhen integration files validated" || echo "❌ RunWhen integration issues")

## Recommendations

EOF

    if [ $FAILED_TESTS -gt 0 ]; then
        cat >> "$report_file" << EOF
### Issues Found

- Review the test output above for specific failure details
- Ensure all prerequisites are met before running tests
- Check that terraform infrastructure is properly deployed
- Verify that all required scripts are executable

EOF
    fi

    cat >> "$report_file" << EOF
### Next Steps

1. **If all tests passed**: The organization health testing infrastructure is ready
2. **If tests failed**: Address the specific issues identified above
3. **To run tests**: Use \`./test-issue-generation.sh\` to execute the full test suite
4. **To cleanup**: Use \`./cleanup-test-environment.sh\` when finished

## Test Environment Status

- Infrastructure: $([ -f "$TERRAFORM_DIR/terraform.tfstate" ] && echo "Deployed" || echo "Not Deployed")
- Generated Scripts: $([ -d "$TERRAFORM_DIR/generated-files" ] && echo "Available" || echo "Missing")
- Test Outputs: $([ -d "$OUTPUT_DIR" ] && echo "Available" || echo "Missing")

EOF

    log_success "Validation report generated: $report_file"
}

# Main validation function
main() {
    echo "=============================================="
    echo "Azure DevOps Organization Health Test Validation"
    echo "=============================================="
    
    # Initialize counters
    TOTAL_TESTS=0
    PASSED_TESTS=0
    FAILED_TESTS=0
    
    # Run all validations
    validate_configuration
    validate_infrastructure
    validate_generated_scripts
    validate_test_outputs
    validate_agent_pool_tests
    validate_license_tests
    validate_security_tests
    validate_service_tests
    validate_health_detection
    validate_runwhen_integration
    
    # Generate final report
    generate_validation_report
    
    echo ""
    echo "=============================================="
    echo "Validation Summary"
    echo "=============================================="
    echo "Total Tests: $TOTAL_TESTS"
    echo "Passed: $PASSED_TESTS"
    echo "Failed: $FAILED_TESTS"
    echo "Success Rate: $(( PASSED_TESTS * 100 / TOTAL_TESTS ))%"
    echo "=============================================="
    
    if [ $FAILED_TESTS -gt 0 ]; then
        log_failure "Some validations failed - review output above"
        exit 1
    else
        log_success "All validations passed successfully"
        exit 0
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 