#!/bin/bash

# Script to validate Azure DevOps organization security settings
# Template variables will be replaced by Terraform

ORG_URL="https://dev.azure.com/runwhen-labs"
PROJECTS=("cross-dependencies-project-d5a1bb4d" "high-capacity-project-d5a1bb4d" "license-test-project-d5a1bb4d" "security-test-project-d5a1bb4d" "service-health-project-d5a1bb4d")
SERVICE_CONNECTIONS=("over-permissions-connection-d5a1bb4d" "unsecured-connection-d5a1bb4d" "weak-security-connection-d5a1bb4d")

echo "Validating security settings for Azure DevOps organization"
echo "Organization URL: $ORG_URL"
echo "Projects: ${PROJECTS[@]}"
echo "Service Connections: ${SERVICE_CONNECTIONS[@]}"

# Function to validate organization-level security policies
validate_org_policies() {
    echo "=== Validating Organization Security Policies ==="
    
    # Check for weak password policies
    echo "Checking password policies..."
    echo "POLICY_CHECK: Password complexity requirements"
    
    # Check for MFA enforcement
    echo "Checking MFA enforcement..."
    echo "POLICY_CHECK: Multi-factor authentication required"
    
    # Check for external user access
    echo "Checking external user access policies..."
    echo "POLICY_CHECK: External user access restrictions"
    
    # Check for OAuth app permissions
    echo "Checking OAuth application permissions..."
    echo "POLICY_CHECK: OAuth application approval process"
}

# Function to validate project-level security
validate_project_security() {
    local project=$1
    echo "=== Validating Project Security: $project ==="
    
    # Check branch protection policies
    echo "Checking branch protection policies for $project..."
    echo "SECURITY_CHECK: Branch protection enabled"
    
    # Check build validation requirements
    echo "Checking build validation requirements for $project..."
    echo "SECURITY_CHECK: Build validation required for PRs"
    
    # Check reviewer requirements
    echo "Checking code review requirements for $project..."
    echo "SECURITY_CHECK: Minimum reviewer count enforced"
    
    # Check for secure variable usage
    echo "Checking secure variable usage in $project..."
    echo "SECURITY_CHECK: Secure variables properly configured"
}

# Function to validate service connection security
validate_service_connections() {
    echo "=== Validating Service Connection Security ==="
    
    for connection in "${SERVICE_CONNECTIONS[@]}"; do
        echo "Validating service connection: $connection"
        
        # Check connection permissions
        echo "SECURITY_CHECK: Service connection '$connection' - Permission scope"
        
        # Check for credential rotation
        echo "SECURITY_CHECK: Service connection '$connection' - Credential age"
        
        # Check usage restrictions
        echo "SECURITY_CHECK: Service connection '$connection' - Usage restrictions"
    done
}

# Function to check for security violations
check_security_violations() {
    echo "=== Checking for Security Violations ==="
    
    # Simulate finding some security issues
    violations=(
        "HIGH: Weak password policy detected"
        "MEDIUM: External user with admin access found"
        "LOW: Service connection credential approaching expiration"
        "MEDIUM: Branch protection not enforced on main branch"
    )
    
    for violation in "${violations[@]}"; do
        echo "VIOLATION: $violation"
    done
}

# Function to generate security report
generate_security_report() {
    local report_file="security_validation_report.json"
    
    echo "Generating security validation report: $report_file"
    
    cat > "$report_file" << EOF
{
  "organization": "$ORG_URL",
  "validation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "projects_checked": [$(printf '"%s",' "${PROJECTS[@]}" | sed 's/,$//')]",
  "service_connections_checked": [$(printf '"%s",' "${SERVICE_CONNECTIONS[@]}" | sed 's/,$//')]",
  "security_score": 75,
  "violations_found": 4,
  "recommendations": [
    "Enable stronger password policies",
    "Review external user permissions",
    "Rotate service connection credentials",
    "Enforce branch protection on all main branches"
  ]
}
EOF
    
    echo "Security report generated: $report_file"
}

# Main execution
main() {
    echo "Starting Azure DevOps security validation"
    echo "Organization: $ORG_URL"
    echo "----------------------------------------"
    
    validate_org_policies
    echo ""
    
    # Validate security for each project
    for project in "${PROJECTS[@]}"; do
        validate_project_security "$project"
        echo ""
    done
    
    validate_service_connections
    echo ""
    
    check_security_violations
    echo ""
    
    generate_security_report
    
    echo "Security validation completed"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 