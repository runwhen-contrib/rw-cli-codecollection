#!/bin/bash

# Test issue generation script for Azure DevOps Organization Health
# This script sets up various organization-level issues to test the health monitoring

set -e

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed or not in PATH"
        exit 1
    fi
    
    # Check if Azure CLI is available
    if ! command -v az &> /dev/null; then
        log_warning "Azure CLI not found - some features may not work"
    fi
    
    # Check if terraform directory exists
    if [ ! -d "$TERRAFORM_DIR" ]; then
        log_error "Terraform directory not found: $TERRAFORM_DIR"
        exit 1
    fi
    
    # Check if tf.secret exists
    if [ ! -f "$TERRAFORM_DIR/tf.secret" ]; then
        log_error "tf.secret file not found in $TERRAFORM_DIR"
        echo "Please create tf.secret with required environment variables:"
        echo "export ARM_SUBSCRIPTION_ID=\"your-subscription-id\""
        echo "export ARM_TENANT_ID=\"your-tenant-id\""
        echo "export ARM_CLIENT_ID=\"your-client-id\""
        echo "export ARM_CLIENT_SECRET=\"your-client-secret\""
        echo "export AZDO_PERSONAL_ACCESS_TOKEN=\"your-pat-token\""
        exit 1
    fi
    
    log_success "Prerequisites check completed"
}

# Function to initialize terraform infrastructure
initialize_infrastructure() {
    log_info "Initializing test infrastructure..."
    
    cd "$TERRAFORM_DIR"
    
    # Source the secrets
    source tf.secret
    
    # Initialize terraform
    terraform init
    
    # Plan infrastructure
    log_info "Planning infrastructure..."
    terraform plan -out=tfplan
    
    # Apply infrastructure
    log_info "Creating test infrastructure..."
    terraform apply tfplan
    
    log_success "Test infrastructure created successfully"
    
    cd "$SCRIPT_DIR"
}

# Function to generate agent pool capacity issues
generate_agent_pool_issues() {
    log_info "Generating agent pool capacity issues..."
    
    # Run agent load scripts
    if [ -d "$TERRAFORM_DIR/generated-files" ]; then
        for script in "$TERRAFORM_DIR/generated-files"/*-load-script.sh; do
            if [ -f "$script" ]; then
                log_info "Running agent load script: $(basename "$script")"
                chmod +x "$script"
                "$script" &
                
                # Store PID for cleanup
                echo $! >> /tmp/agent_load_pids.txt
            fi
        done
    fi
    
    log_success "Agent pool load generation started"
}

# Function to generate license utilization issues
generate_license_issues() {
    log_info "Generating license utilization issues..."
    
    # Run license analysis script
    local license_script="$TERRAFORM_DIR/generated-files/license-analysis.sh"
    if [ -f "$license_script" ]; then
        chmod +x "$license_script"
        "$license_script"
    fi
    
    log_success "License utilization analysis completed"
}

# Function to generate security policy violations
generate_security_issues() {
    log_info "Generating security policy violations..."
    
    # Run security validation script
    local security_script="$TERRAFORM_DIR/generated-files/security-validation.sh"
    if [ -f "$security_script" ]; then
        chmod +x "$security_script"
        "$security_script"
    fi
    
    log_success "Security policy validation completed"
}

# Function to generate cross-project dependency issues
generate_dependency_issues() {
    log_info "Generating cross-project dependency issues..."
    
    # Run dependency setup script
    local dependency_script="$TERRAFORM_DIR/generated-files/dependency-setup.sh"
    if [ -f "$dependency_script" ]; then
        chmod +x "$dependency_script"
        "$dependency_script"
    fi
    
    log_success "Cross-project dependencies configured"
}

# Function to simulate service connectivity issues
simulate_service_issues() {
    log_info "Simulating service connectivity issues..."
    
    # This would typically involve:
    # - Temporarily modifying service connection credentials
    # - Introducing network delays
    # - Simulating API rate limiting
    
    log_warning "Service connectivity simulation requires manual intervention"
    log_info "To simulate service issues:"
    echo "  1. Modify service connection credentials in Azure DevOps"
    echo "  2. Introduce network delays using tools like tc (traffic control)"
    echo "  3. Temporarily block API endpoints using firewall rules"
    
    log_success "Service issue simulation guidelines provided"
}

# Function to run validation tests
run_validation_tests() {
    log_info "Running validation tests..."
    
    # Run the organization health runbook to validate issues are detected
    local codebundle_dir="$(dirname "$SCRIPT_DIR")"
    
    if [ -f "$codebundle_dir/runbook.robot" ]; then
        log_info "Running organization health runbook..."
        
        # Source terraform outputs for environment variables
        cd "$TERRAFORM_DIR"
        source tf.secret
        
        local org_name=$(terraform output -raw devops_org)
        local resource_group=$(terraform output -raw resource_group_name)
        
        cd "$codebundle_dir"
        
        # Run robot framework tests
        robot -v AZURE_DEVOPS_ORG:"$org_name" \
              -v AZURE_RESOURCE_GROUP:"$resource_group" \
              -v AGENT_UTILIZATION_THRESHOLD:80 \
              -v LICENSE_UTILIZATION_THRESHOLD:90 \
              -d "$SCRIPT_DIR/output/validation" \
              runbook.robot
        
        log_success "Validation tests completed"
    else
        log_warning "Runbook not found - skipping validation tests"
    fi
    
    cd "$SCRIPT_DIR"
}

# Function to generate test report
generate_test_report() {
    log_info "Generating test report..."
    
    local report_file="$SCRIPT_DIR/test-report.md"
    
    cat > "$report_file" << EOF
# Azure DevOps Organization Health Test Report

Generated on: $(date)

## Test Environment Summary

$(cd "$TERRAFORM_DIR" && terraform output test_environment_summary 2>/dev/null || echo "Infrastructure not deployed")

## Generated Test Issues

### Agent Pool Capacity Issues
- Overutilized agent pools (>80% utilization)
- Offline agents simulation
- Undersized pools with insufficient capacity

### License Utilization Issues  
- High license usage (>90% threshold)
- Inactive licensed users
- Misaligned access level assignments
- Visual Studio subscriber benefit underutilization

### Security Policy Violations
- Weak organization security policies
- Over-permissioned user accounts
- Unsecured service connections
- Missing compliance requirements

### Service Connectivity Issues
- API connectivity problems (simulated)
- Authentication failures
- Performance degradation scenarios

### Cross-Project Dependencies
- Shared resource conflicts
- Dependency chain failures
- Variable group security issues

## Validation Results

Check the output directory for detailed Robot Framework test results:
- \`output/validation/output.xml\` - Detailed test execution results
- \`output/validation/log.html\` - Test execution log
- \`output/validation/report.html\` - Test summary report

## Cleanup Instructions

To clean up the test environment:

\`\`\`bash
# Stop agent load processes
./cleanup-agent-load.sh

# Destroy terraform infrastructure
cd terraform
terraform destroy -auto-approve
\`\`\`

## Notes

- Test issues are designed to trigger organization health alerts
- Monitor the organization health dashboard for detected issues
- Use this environment to validate monitoring thresholds and alerting
EOF

    log_success "Test report generated: $report_file"
}

# Function to create cleanup script
create_cleanup_script() {
    log_info "Creating cleanup script..."
    
    cat > "$SCRIPT_DIR/cleanup-test-environment.sh" << 'EOF'
#!/bin/bash

# Cleanup script for Azure DevOps Organization Health test environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"

echo "Cleaning up Azure DevOps Organization Health test environment..."

# Stop agent load processes
if [ -f "/tmp/agent_load_pids.txt" ]; then
    echo "Stopping agent load processes..."
    while read pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "Stopped process: $pid"
        fi
    done < /tmp/agent_load_pids.txt
    rm -f /tmp/agent_load_pids.txt
fi

# Clean up terraform infrastructure
if [ -d "$TERRAFORM_DIR" ] && [ -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
    echo "Destroying terraform infrastructure..."
    cd "$TERRAFORM_DIR"
    source tf.secret
    terraform destroy -auto-approve
    echo "Infrastructure destroyed"
fi

# Clean up output files
if [ -d "$SCRIPT_DIR/output" ]; then
    echo "Cleaning up output files..."
    rm -rf "$SCRIPT_DIR/output"
fi

# Clean up generated files
if [ -d "$TERRAFORM_DIR/generated-files" ]; then
    echo "Cleaning up generated files..."
    rm -rf "$TERRAFORM_DIR/generated-files"
fi

echo "Cleanup completed"
EOF

    chmod +x "$SCRIPT_DIR/cleanup-test-environment.sh"
    
    log_success "Cleanup script created: cleanup-test-environment.sh"
}

# Main execution function
main() {
    echo "=============================================="
    echo "Azure DevOps Organization Health Test Setup"
    echo "=============================================="
    
    # Parse command line arguments
    local action="${1:-all}"
    
    case "$action" in
        "prereq"|"prerequisites")
            check_prerequisites
            ;;
        "infra"|"infrastructure")
            check_prerequisites
            initialize_infrastructure
            ;;
        "agents"|"agent-issues")
            generate_agent_pool_issues
            ;;
        "licenses"|"license-issues")
            generate_license_issues
            ;;
        "security"|"security-issues")
            generate_security_issues
            ;;
        "dependencies"|"dependency-issues")
            generate_dependency_issues
            ;;
        "service"|"service-issues")
            simulate_service_issues
            ;;
        "validate"|"validation")
            run_validation_tests
            ;;
        "report")
            generate_test_report
            ;;
        "cleanup")
            if [ -f "$SCRIPT_DIR/cleanup-test-environment.sh" ]; then
                "$SCRIPT_DIR/cleanup-test-environment.sh"
            else
                log_error "Cleanup script not found"
            fi
            ;;
        "all"|"")
            check_prerequisites
            initialize_infrastructure
            generate_agent_pool_issues
            generate_license_issues
            generate_security_issues
            generate_dependency_issues
            simulate_service_issues
            sleep 30  # Allow issues to settle
            run_validation_tests
            generate_test_report
            create_cleanup_script
            ;;
        *)
            echo "Usage: $0 [action]"
            echo "Actions:"
            echo "  prereq        - Check prerequisites only"
            echo "  infra         - Initialize infrastructure only" 
            echo "  agents        - Generate agent pool issues"
            echo "  licenses      - Generate license issues"
            echo "  security      - Generate security issues"
            echo "  dependencies  - Generate dependency issues"
            echo "  service       - Simulate service issues"
            echo "  validate      - Run validation tests"
            echo "  report        - Generate test report"
            echo "  cleanup       - Clean up test environment"
            echo "  all           - Run complete test setup (default)"
            exit 1
            ;;
    esac
    
    log_success "Test issue generation completed successfully"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 